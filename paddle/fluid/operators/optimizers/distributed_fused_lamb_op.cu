// Copyright (c) 2023 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "paddle/fluid/operators/optimizers/multi_tensor_apply.h"
#include "paddle/fluid/platform/collective_helper.h"

#include "paddle/phi/backends/context_pool.h"
#include "paddle/phi/backends/gpu/gpu_launch_config.h"
#include "paddle/phi/common/amp_type_traits.h"
#include "paddle/phi/common/memory_utils.h"
#include "paddle/phi/core/cuda_stream.h"
#include "paddle/phi/core/dense_tensor.h"
#include "paddle/phi/core/distributed/comm_context_manager.h"
#include "paddle/phi/core/distributed/utils.h"
#include "paddle/phi/core/enforce.h"
#include "paddle/phi/core/kernel_registry.h"
#include "paddle/phi/core/utils/data_type.h"
#include "paddle/phi/kernels/funcs/aligned_vector.h"
#include "paddle/phi/kernels/funcs/tensor_to_string.h"
#include "paddle/utils/optional.h"

#if defined(PADDLE_WITH_NCCL) || defined(PADDLE_WITH_RCCL)
#include "paddle/phi/core/distributed/nccl_comm_context.h"
#include "paddle/phi/core/flags.h"
PHI_DECLARE_bool(dynamic_static_unified_comm);
#endif

#ifdef __NVCC__
#include "cub/cub.cuh"
#include "math.h"  // NOLINT
#endif

#ifdef __HIPCC__
#include <hipcub/hipcub.hpp>

#include "math.h"  // NOLINT
namespace cub = hipcub;
#endif

namespace phi {
namespace fusion {

template <typename T>
using MasterT = typename phi::dtype::MPTypeTrait<T>::Type;
using phi::funcs::FlattenToString;
using phi::funcs::ToVector;

static void CheckCommContextHasRingId(
    const distributed::CommContextManager &comm_context_manager, int ring_id) {
  PADDLE_ENFORCE_EQ(comm_context_manager.Has(std::to_string(ring_id)),
                    true,
                    paddle::platform::errors::InvalidArgument(
                        "You choose to use new communication library by "
                        "setting environment "
                        "variable FLAGS_dynamic_static_unified_comm True. "
                        "But ring_id(%d) is "
                        "not found in comm_context_manager.",
                        std::to_string(ring_id)));
}

template <typename T>
static void FillZeroWithPtr(T *x, size_t n, gpuStream_t stream) {
  static_assert(!std::is_same<T, void>::value, "T cannot be void.");
#ifdef PADDLE_WITH_HIP
  PADDLE_ENFORCE_GPU_SUCCESS(hipMemsetAsync(x, 0, n * sizeof(T), stream));
#else
  PADDLE_ENFORCE_GPU_SUCCESS(cudaMemsetAsync(x, 0, n * sizeof(T), stream));
#endif
}

template <typename T, int BlockDim, int VecSize>
struct L2NormFunctor {
  DEVICE void operator()(int tensor_id,
                         int chunk_id,
                         int offset,
                         int size,
                         const T *x,
                         MasterT<T> *y,
                         int max_chunk_num) const {
    using MT = MasterT<T>;
    const T *ptr = x + offset;

    using BlockReduce = cub::BlockReduce<MT, BlockDim>;
    __shared__ typename BlockReduce::TempStorage storage;

    MT square_sum = static_cast<MT>(0);
    int i;
    for (i = threadIdx.x * VecSize; i + VecSize <= size;
         i += (BlockDim * VecSize)) {
      phi::AlignedVector<T, VecSize> tmp_vec;
      phi::Load(ptr + i, &tmp_vec);
#pragma unroll
      for (int j = 0; j < VecSize; ++j) {
        auto tmp = static_cast<MT>(tmp_vec[j]);
        square_sum += (tmp * tmp);
      }
    }

    for (; i < size; ++i) {
      auto tmp = static_cast<MT>(ptr[i]);
      square_sum += (tmp * tmp);
    }

    square_sum = BlockReduce(storage).Reduce(square_sum, cub::Sum());
    if (threadIdx.x == 0) {
      y[tensor_id * max_chunk_num + chunk_id] = square_sum;
    }
  }
};

template <typename InT, typename OutT, int BlockDim>
static __global__ void MultiTensorL2NormReduceAgainCUDAKernel(
    const InT *x, OutT *y, int max_chunk_num) {
  int tensor_id = blockIdx.x;
  x += (tensor_id * max_chunk_num);
  using BlockReduce = cub::BlockReduce<InT, BlockDim>;
  __shared__ typename BlockReduce::TempStorage storage;
  InT sum = static_cast<InT>(0);
  for (int i = threadIdx.x; i < max_chunk_num; i += BlockDim) {
    sum += x[i];
  }
  sum = BlockReduce(storage).Reduce(sum, cub::Sum());
  if (threadIdx.x == 0) {
    y[blockIdx.x] = static_cast<OutT>(sum);
  }
}

template <typename T>
static int GetChunkedVecSize(const T *ptr, int chunk_size) {
  static_assert(!std::is_same<T, void>::value, "T cannot be void.");

  constexpr int max_load_bits = 128;
  int valid_vec_size = max_load_bits / CHAR_BIT / sizeof(T);
  auto address = reinterpret_cast<uintptr_t>(ptr);
  constexpr int vec8 = alignof(phi::AlignedVector<T, 8>);
  constexpr int vec4 = alignof(phi::AlignedVector<T, 4>);
  constexpr int vec2 = alignof(phi::AlignedVector<T, 2>);
  chunk_size *= sizeof(T);
  if (address % vec8 == 0 && chunk_size % vec8 == 0) {
    return std::min(8, valid_vec_size);
  } else if (address % vec4 == 0 && chunk_size % vec4 == 0) {
    return std::min(4, valid_vec_size);
  } else if (address % vec2 == 0 && chunk_size % vec2 == 0) {
    return std::min(2, valid_vec_size);
  } else {
    return 1;
  }
}

#define PD_VEC_LAUNCH_KERNEL_CASE(__vec_size, ...) \
  case __vec_size: {                               \
    constexpr int kVecSize = __vec_size;           \
    __VA_ARGS__;                                   \
    break;                                         \
  }

#define PD_VEC_LAUNCH_KERNEL(__vec_size, ...)    \
  do {                                           \
    switch (__vec_size) {                        \
      PD_VEC_LAUNCH_KERNEL_CASE(8, __VA_ARGS__); \
      PD_VEC_LAUNCH_KERNEL_CASE(4, __VA_ARGS__); \
      PD_VEC_LAUNCH_KERNEL_CASE(2, __VA_ARGS__); \
      PD_VEC_LAUNCH_KERNEL_CASE(1, __VA_ARGS__); \
    }                                            \
  } while (0)

// TODO(zengjinle): which chunk_size is better?
template <typename InT,
          typename OutT,
          int MaxTensorNumPerLaunch = 160,
          int MaxChunkNumPerLaunch = 780>
static void MultiTensorL2Norm(const phi::GPUPlace &place,
                              gpuStream_t stream,
                              const InT *x,
                              const int *offsets,
                              int n,
                              OutT *y,
                              int chunk_size = 65536) {
  if (n <= 0) return;

  constexpr int kNumTensor = MaxTensorNumPerLaunch;
  constexpr int kNumChunk = MaxChunkNumPerLaunch;
  constexpr int kBlockDim = 512;

  int max_chunk_num = -1;
  int vec_size = 8;
  int total_chunk_num = 0;
  for (int i = 0; i < n; ++i) {
    vec_size = std::min(
        vec_size, GetChunkedVecSize(x + offsets[i] - offsets[0], chunk_size));
    int length = offsets[i + 1] - offsets[i];
    auto tmp_chunk_num = (length + chunk_size - 1) / chunk_size;
    max_chunk_num = std::max(max_chunk_num, tmp_chunk_num);
    total_chunk_num += tmp_chunk_num;
  }

  VLOG(1) << "MultiTensorL2Norm max_chunk_num = " << max_chunk_num
          << " , total_chunk_num = " << total_chunk_num
          << " , tensor_num = " << n;

  using MT = MasterT<InT>;
  memory_utils::Buffer tmp_out(place);
  auto *tmp_out_ptr = tmp_out.Alloc<MT>(n * max_chunk_num);
  FillZeroWithPtr(tmp_out_ptr, n * max_chunk_num, stream);

#define PD_LAUNCH_MULTI_TENSOR_APPLY_L2_NORM_KERNEL                       \
  do {                                                                    \
    using FunctorT = L2NormFunctor<InT, kBlockDim, kVecSize>;             \
    VLOG(10) << __func__ << " " << typeid(InT).name()                     \
             << " VecSize = " << kVecSize;                                \
    paddle::operators::MultiTensorApply<FunctorT, kNumTensor, kNumChunk>( \
        FunctorT(),                                                       \
        stream,                                                           \
        offsets,                                                          \
        n,                                                                \
        chunk_size,                                                       \
        kBlockDim,                                                        \
        x,                                                                \
        tmp_out_ptr,                                                      \
        max_chunk_num);                                                   \
  } while (0)

  PD_VEC_LAUNCH_KERNEL(vec_size, PD_LAUNCH_MULTI_TENSOR_APPLY_L2_NORM_KERNEL);
#undef PD_LAUNCH_MULTI_TENSOR_APPLY_L2_NORM_KERNEL

  MultiTensorL2NormReduceAgainCUDAKernel<MT, OutT, kBlockDim>
      <<<n, kBlockDim, 0, stream>>>(tmp_out_ptr, y, max_chunk_num);
}

template <int LogLevel>
static void LogParamAndTrustRatioDivSquareNorm(
    const std::vector<const DenseTensor *> &param,
    const DenseTensor &order,
    const float *param_square_norm,
    const float *trust_ratio_div_square_norm) {
  if (!VLOG_IS_ON(LogLevel)) return;

  if (param.empty()) return;

  const auto *order_data = order.data<int>();

  size_t n = param.size();
  auto place = param[0]->place();

  auto pn_vec = ToVector(param_square_norm, n, place);
  auto tn_vec = ToVector(trust_ratio_div_square_norm, n, place);

  for (size_t i = 0; i < n; ++i) {
    auto idx = order_data[i];
    VLOG(LogLevel) << "Param " << param[idx]->dtype() << " "
                   << param[idx]->name() << " pn = " << pn_vec[i]
                   << " , tn = " << tn_vec[i];
  }
}

static bool IsFinite(const phi::GPUContext &dev_ctx, const float *ptr) {
  auto stream = dev_ctx.stream();
  float cpu_value;
#ifdef PADDLE_WITH_HIP
  PADDLE_ENFORCE_GPU_SUCCESS(hipMemcpyAsync(
      &cpu_value, ptr, sizeof(float), hipMemcpyDeviceToHost, stream));
  PADDLE_ENFORCE_GPU_SUCCESS(hipStreamSynchronize(stream));
#else
  PADDLE_ENFORCE_GPU_SUCCESS(cudaMemcpyAsync(
      &cpu_value, ptr, sizeof(float), cudaMemcpyDeviceToHost, stream));
  PADDLE_ENFORCE_GPU_SUCCESS(cudaStreamSynchronize(stream));
#endif
  LOG(INFO) << "NAN_INF indicator value: " << cpu_value;
  return isfinite(cpu_value);
}

template <typename T>
static const T *GetInputTensorPtr(const DenseTensor *in_tensor,
                                  const char *in_name,
                                  int64_t *numel = nullptr) {
  PADDLE_ENFORCE_NOT_NULL(
      in_tensor,
      phi::errors::InvalidArgument("Input(%s) cannot be NULL.", in_name));
  if (in_tensor->initialized()) {
    if (numel) *numel = in_tensor->numel();
    return in_tensor->data<T>();
  } else {
    if (numel) *numel = 0;
    return nullptr;
  }
}

template <typename T, typename Context, bool AllowNotExist = false>
static T *GetSameInOutTensorPtr(const Context &dev_ctx,
                                const DenseTensor *in_tensor,
                                DenseTensor *out_tensor,
                                const char *in_name,
                                const char *out_name,
                                int64_t *numel = nullptr) {
  if (in_tensor == nullptr || !in_tensor->initialized()) {
    PADDLE_ENFORCE_EQ(
        AllowNotExist,
        true,
        phi::errors::InvalidArgument("Input(%s) cannot be NULL.", in_name));
    if (numel) *numel = 0;
    return nullptr;
  }

  PADDLE_ENFORCE_NOT_NULL(
      in_tensor,
      phi::errors::InvalidArgument("Input(%s) cannot be NULL.", in_name));
  PADDLE_ENFORCE_NOT_NULL(
      out_tensor,
      phi::errors::InvalidArgument("Output(%s) cannot be NULL.", out_name));
  const T *in_data = in_tensor->data<T>();

  T *out_data = dev_ctx.template Alloc<T>(out_tensor);
  PADDLE_ENFORCE_EQ(in_data,
                    out_data,
                    phi::errors::InvalidArgument(
                        "Input(%s) and Output(%s) must be the same Tensor.",
                        in_name,
                        out_name));
  if (numel) *numel = out_tensor->numel();
  return out_data;
}

template <typename T>
struct SquareFunctor {
  HOSTDEVICE MasterT<T> operator()(T x) const {
    auto y = static_cast<MasterT<T>>(x);
    return y * y;
  }
};

template <typename T>
struct IsNanInfFunctor {
  HOSTDEVICE bool operator()(T x) const { return !isfinite(x); }
};

struct OrFunctor {
  HOSTDEVICE bool operator()(bool x, bool y) const { return x || y; }
};

struct AndFunctor {
  HOSTDEVICE bool operator()(bool x, bool y) const { return x && y; }
};

template <typename T1, typename T2, int VecSize>
static __global__ void ScaleCUDAKernel(const T1 *__restrict__ x,
                                       const T2 *__restrict__ scale,
                                       T1 *__restrict__ y,
                                       int num) {
  static_assert(sizeof(T1) <= sizeof(T2),
                "sizeof(T1) must be not greater than sizeof(T2).");
  T2 s = scale[0];

  int i = (threadIdx.x + blockIdx.x * blockDim.x) * VecSize;
  int stride = blockDim.x * gridDim.x * VecSize;

  for (; i + VecSize <= num; i += stride) {
    phi::AlignedVector<T1, VecSize> x_vec;
    phi::AlignedVector<T1, VecSize> y_vec;

    phi::Load(x + i, &x_vec);
#pragma unroll
    for (int j = 0; j < VecSize; ++j) {
      y_vec[j] = static_cast<T1>(static_cast<T2>(x_vec[j]) * s);
    }
    phi::Store(y_vec, y + i);
  }

  for (; i < num; ++i) {
    y[i] = static_cast<T1>(static_cast<T2>(x[i]) * s);
  }
}

template <typename T>
static __global__ void AddToCUDAKernel(const T *__restrict__ x,
                                       T *__restrict__ y) {
  y[0] += x[0];
}

// If clip before allreduce,
// coeff = global_scale * max_global_grad_norm / (1e-6 + sqrt(square_grad_norm)
// * rescale_grad)
// if coeff >= 1 or coeff is Nan/Inf, scale = 1.0
// else scale = coeff
template <typename T1, typename T2>
static __global__ void CalcGradNormClipBeforeAllReduceScale(
    const T1 *__restrict__ global_scale,
    T1 max_global_grad_norm,
    const T1 *__restrict__ square_grad_norm,
    T1 *__restrict__ out1,
    T2 *__restrict__ out2,
    T1 clip_rescale_grad) {
  T1 grad_norm = static_cast<T1>(sqrtf(*square_grad_norm)) * clip_rescale_grad;
  T1 scale = global_scale[0] * max_global_grad_norm / (1e-6 + grad_norm);
  bool found_nan_inf = !isfinite(scale);
  if (scale >= 1 || found_nan_inf) {
    scale = static_cast<T1>(1.0);
  }

  if (out1) {
    *out1 = scale;
  }
  if (out2) {
    *out2 = static_cast<T2>(scale);
  }
}

static __global__ void SetNanInfValueCUDAKernelOneFlag(const bool *in_flag_p,
                                                       float *out_p) {
  *out_p = (*in_flag_p) ? __int_as_float(0x7fffffffU) : 0.0f;
}

static __global__ void SetNanInfValueCUDAKernelTwoFlag(const bool *in_flag_p_1,
                                                       const bool *in_flag_p_2,
                                                       float *out_p) {
  *out_p =
      ((*in_flag_p_1) || (*in_flag_p_2)) ? __int_as_float(0x7fffffffU) : 0.0f;
}

template <typename T, typename GradT, int VecSize>
static __global__ void UpdateLambMomentAndTrustRatioDivCUDAKernel(
    const T *__restrict__ param_p,
    const GradT *__restrict__ grad_p,
    const T *__restrict__ square_grad_norm_p,
    const T *__restrict__ global_scale,
    const T *__restrict__ beta1pow_p,
    const T *__restrict__ beta2pow_p,
    T *__restrict__ mom1_p,
    T *__restrict__ mom2_p,
    T *__restrict__ trust_ratio_div_p,
    bool *__restrict__ found_inf,
    int64_t *__restrict__ step,
    T weight_decay,
    int weight_decay_end_numel,
    T beta1,
    T beta2,
    T epsilon,
    T max_global_grad_norm,
    int num,
    T rescale_grad) {
  T square_grad_norm = *square_grad_norm_p;
  bool need_update_found_inf =
      (found_inf && threadIdx.x == 0 && blockIdx.x == 0);
  if (!isfinite(square_grad_norm)) {
    if (need_update_found_inf) *found_inf = true;
    return;
  } else if (need_update_found_inf) {
    *found_inf = false;
    ++(*step);
  }

  T scale = rescale_grad / global_scale[0];
  if (max_global_grad_norm > 0) {
    T clip_scale =
        max_global_grad_norm / (sqrtf(square_grad_norm) * scale + 1e-6);
    if (clip_scale < static_cast<T>(1)) {
      scale *= clip_scale;
    }
  }

  T one_minus_beta1pow = 1 - beta1pow_p[0];
  T one_minus_beta2pow = 1 - beta2pow_p[0];

  int i = (threadIdx.x + blockIdx.x * blockDim.x) * VecSize;
  int stride = blockDim.x * gridDim.x * VecSize;

  for (; i + VecSize <= num; i += stride) {
    phi::AlignedVector<T, VecSize> param_vec;
    phi::AlignedVector<GradT, VecSize> grad_vec;
    phi::AlignedVector<T, VecSize> mom1_vec;
    phi::AlignedVector<T, VecSize> mom2_vec;
    phi::AlignedVector<T, VecSize> trust_ratio_div_vec;

    T cur_weight_decay = (i < weight_decay_end_numel) * weight_decay;
    if (cur_weight_decay != static_cast<T>(0.0)) {
      phi::Load(param_p + i, &param_vec);
    } else {
#pragma unroll
      for (int j = 0; j < VecSize; ++j) {
        param_vec[j] = static_cast<T>(0);
      }
    }
    phi::Load(grad_p + i, &grad_vec);
    phi::Load(mom1_p + i, &mom1_vec);
    phi::Load(mom2_p + i, &mom2_vec);

#define PD_LAMB_MOM_TRUST_RATIO_DIV_UPDATE(                                    \
    __param, __grad, __mom1, __mom2, __trust_ratio_div, __idx)                 \
  T p = __param[__idx];                                                        \
  T g = static_cast<T>(__grad[__idx]) * scale;                                 \
  T mom1 = __mom1[__idx];                                                      \
  T mom2 = __mom2[__idx];                                                      \
  mom1 = beta1 * mom1 + (1 - beta1) * g;                                       \
  mom2 = beta2 * mom2 + (1 - beta2) * g * g;                                   \
  T mom1_unbiased = mom1 / one_minus_beta1pow;                                 \
  T mom2_unbiased = mom2 / one_minus_beta2pow;                                 \
  __trust_ratio_div[__idx] =                                                   \
      mom1_unbiased / (sqrtf(mom2_unbiased) + epsilon) + cur_weight_decay * p; \
  __mom1[__idx] = mom1;                                                        \
  __mom2[__idx] = mom2;

#pragma unroll
    for (int j = 0; j < VecSize; ++j) {
      PD_LAMB_MOM_TRUST_RATIO_DIV_UPDATE(
          param_vec, grad_vec, mom1_vec, mom2_vec, trust_ratio_div_vec, j);
    }

    phi::Store(mom1_vec, mom1_p + i);
    phi::Store(mom2_vec, mom2_p + i);
    phi::Store(trust_ratio_div_vec, trust_ratio_div_p + i);
  }

  for (; i < num; ++i) {
    T cur_weight_decay = (i < weight_decay_end_numel) * weight_decay;
    PD_LAMB_MOM_TRUST_RATIO_DIV_UPDATE(
        param_p, grad_p, mom1_p, mom2_p, trust_ratio_div_p, i);
  }
}

template <typename T, typename GradT>
static void MultiTensorUpdateLambMomentAndTrustRatioDiv(
    const phi::GPUContext &dev_ctx,
    const int *offsets,
    int n,
    const T *param_p,
    const GradT *grad_p,
    const T *square_grad_norm_p,
    const T *global_scale,
    const T *beta1pow_p,
    const T *beta2pow_p,
    T *mom1_p,
    T *mom2_p,
    T *trust_ratio_div_p,
    bool *found_inf_p,
    int64_t *step,
    T weight_decay,
    int weight_decay_end_idx,
    T beta1,
    T beta2,
    T epsilon,
    T max_global_grad_norm,
    T rescale_grad) {
  if (n <= 0) return;
  int numel = offsets[n] - offsets[0];
  PADDLE_ENFORCE_GE(weight_decay_end_idx,
                    0,
                    phi::errors::InvalidArgument(
                        "The weight decay end index should be >= 0."));
  PADDLE_ENFORCE_LE(weight_decay_end_idx,
                    n,
                    phi::errors::InvalidArgument(
                        "The weight decay end index should be < %d.", n));
  auto weight_decay_end_numel = offsets[weight_decay_end_idx] - offsets[0];

  int vec_size = GetChunkedVecSize(param_p, 0);
  vec_size = std::min(vec_size, GetChunkedVecSize(grad_p, 0));
  vec_size = std::min(vec_size, GetChunkedVecSize(mom1_p, 0));
  vec_size = std::min(vec_size, GetChunkedVecSize(mom2_p, 0));
  vec_size = std::min(vec_size, GetChunkedVecSize(trust_ratio_div_p, 0));
  for (int i = 0; i < n; ++i) {
    auto length = offsets[i + 1] - offsets[i];
    while (length % vec_size != 0) {
      vec_size /= 2;
    }
  }

  VLOG(1) << __func__ << " VecSize = " << vec_size;

  auto stream = dev_ctx.stream();
  auto config =
      phi::backends::gpu::GetGpuLaunchConfig1D(dev_ctx, numel, vec_size);
  if (found_inf_p == nullptr) {
    PADDLE_ENFORCE_EQ(
        step,
        nullptr,
        phi::errors::InvalidArgument(
            "Output(Step) cannot be updated twice in one mini-batch."));
  } else {
    PADDLE_ENFORCE_NOT_NULL(
        step, phi::errors::InvalidArgument("Output(Step) cannot be nullptr."));
  }

#define PD_LAUNCH_LAMB_MOM_TRUST_RATIO_DIV_KERNEL                        \
  do {                                                                   \
    UpdateLambMomentAndTrustRatioDivCUDAKernel<T, GradT, kVecSize>       \
        <<<config.block_per_grid, config.thread_per_block, 0, stream>>>( \
            param_p,                                                     \
            grad_p,                                                      \
            square_grad_norm_p,                                          \
            global_scale,                                                \
            beta1pow_p,                                                  \
            beta2pow_p,                                                  \
            mom1_p,                                                      \
            mom2_p,                                                      \
            trust_ratio_div_p,                                           \
            found_inf_p,                                                 \
            step,                                                        \
            weight_decay,                                                \
            weight_decay_end_numel,                                      \
            beta1,                                                       \
            beta2,                                                       \
            epsilon,                                                     \
            max_global_grad_norm,                                        \
            numel,                                                       \
            rescale_grad);                                               \
  } while (0)

  PD_VEC_LAUNCH_KERNEL(vec_size, PD_LAUNCH_LAMB_MOM_TRUST_RATIO_DIV_KERNEL);
#undef PD_LAUNCH_LAMB_MOM_TRUST_RATIO_DIV_KERNEL
}

template <typename T, bool NeedUpdate /*=true*/>
struct LambBetaPowUpdateOnceHelper {
  LambBetaPowUpdateOnceHelper(T *beta1pow, T *beta2pow, T beta1, T beta2) {
    PADDLE_ENFORCE_NOT_NULL(
        beta1pow,
        phi::errors::InvalidArgument("The beta1pow should not be nullptr."));
    PADDLE_ENFORCE_NOT_NULL(
        beta2pow,
        phi::errors::InvalidArgument("The beta2pow should not be nullptr."));
    beta1pow_ = beta1pow;
    beta2pow_ = beta2pow;
    beta1_ = beta1;
    beta2_ = beta2;
  }

  HOSTDEVICE void UpdateBetaPows() const {
    beta1pow_[0] *= beta1_;
    beta2pow_[0] *= beta2_;
  }

 private:
  T *__restrict__ beta1pow_;
  T *__restrict__ beta2pow_;
  T beta1_;
  T beta2_;
};

template <typename T>
struct LambBetaPowUpdateOnceHelper<T, false> {
  LambBetaPowUpdateOnceHelper(T *beta1pow, T *beta2pow, T beta1, T beta2) {
    PADDLE_ENFORCE_EQ(
        beta1pow,
        nullptr,
        phi::errors::InvalidArgument("The beta1pow should be nullptr."));
    PADDLE_ENFORCE_EQ(
        beta2pow,
        nullptr,
        phi::errors::InvalidArgument("The beta2pow should be nullptr."));
  }

  HOSTDEVICE void UpdateBetaPows() const {}
};

template <typename T, bool HasMasterParam /*=true*/>
struct LambParamHelper {
  LambParamHelper(T *param, MasterT<T> *master_param) {
    constexpr bool kIsSameType = std::is_same<T, MasterT<T>>::value;
    PADDLE_ENFORCE_EQ(kIsSameType,
                      false,
                      phi::errors::InvalidArgument(
                          "T must not be the same with MasterT<T>."));
    PADDLE_ENFORCE_NOT_NULL(
        master_param,
        phi::errors::InvalidArgument("Master parameter must be provided."));
    param_ = param;
    master_param_ = master_param;
  }

  HOSTDEVICE T *__restrict__ ParamPtr() { return param_; }

  HOSTDEVICE MasterT<T> *__restrict__ MasterParamPtr() { return master_param_; }

 private:
  T *__restrict__ param_;
  MasterT<T> *__restrict__ master_param_;
};

template <typename T>
struct LambParamHelper<T, false> {
  LambParamHelper(T *param, MasterT<T> *master_param) {
    constexpr bool kIsSameType = std::is_same<T, MasterT<T>>::value;
    PADDLE_ENFORCE_EQ(
        kIsSameType,
        true,
        phi::errors::InvalidArgument("T must be the same with MasterT<T>."));
    if (master_param != nullptr) {
      PADDLE_ENFORCE_EQ(static_cast<void *>(param),
                        static_cast<void *>(master_param),
                        phi::errors::InvalidArgument(
                            "Master parameter must be nullptr or the same as "
                            "non-master parameter."));
    }
    param_ = param;
  }

  HOSTDEVICE T *__restrict__ ParamPtr() { return param_; }

  HOSTDEVICE constexpr MasterT<T> *MasterParamPtr() { return nullptr; }

 private:
  T *__restrict__ param_;
};

template <typename ParamT,
          bool HasMasterParam,
          bool NeedUpdateBetaPow,
          int VecSize>
struct LambUpdateParamAndBetaPowsFunctor {
  DEVICE void operator()(
      int tensor_id,
      int chunk_id,
      int offset,
      int size,
      LambParamHelper<ParamT, HasMasterParam> param_helper,
      const MasterT<ParamT> *trust_ratio_div,
      const MasterT<ParamT> *lr,
      const MasterT<ParamT> *param_square_norm,
      const MasterT<ParamT> *trust_ratio_div_square_norm,
      const bool *found_inf,
      LambBetaPowUpdateOnceHelper<MasterT<ParamT>, NeedUpdateBetaPow>
          betapow_helper) const {
    if (*found_inf) return;

    using MT = MasterT<ParamT>;

    MT p_square_norm = param_square_norm[tensor_id];
    MT t_square_norm = trust_ratio_div_square_norm[tensor_id];
    MT lr_value = *lr;
    MT ratio = (p_square_norm != static_cast<MT>(0) &&
                        t_square_norm != static_cast<MT>(0)
                    ? lr_value * sqrtf(p_square_norm / t_square_norm)
                    : lr_value);

    int i;
    int stride = blockDim.x * VecSize;

    ParamT *param = param_helper.ParamPtr() + offset;
    MT *master_param = HasMasterParam ? param_helper.MasterParamPtr() + offset
                                      : param_helper.MasterParamPtr();
    trust_ratio_div += offset;

    for (i = threadIdx.x * VecSize; i + VecSize <= size; i += stride) {
      phi::AlignedVector<MT, VecSize> trust_ratio_div_vec;
      phi::Load(trust_ratio_div + i, &trust_ratio_div_vec);
      if (HasMasterParam) {
        phi::AlignedVector<MT, VecSize> master_param_vec;
        phi::Load(master_param + i, &master_param_vec);
        phi::AlignedVector<ParamT, VecSize> param_vec;
#pragma unroll
        for (int j = 0; j < VecSize; ++j) {
          MT p = master_param_vec[j] - ratio * trust_ratio_div_vec[j];
          master_param_vec[j] = p;
          param_vec[j] = static_cast<ParamT>(p);
        }
        phi::Store(master_param_vec, master_param + i);
        phi::Store(param_vec, param + i);
      } else {
        phi::AlignedVector<ParamT, VecSize> param_vec;
        phi::Load(param + i, &param_vec);
#pragma unroll
        for (int j = 0; j < VecSize; ++j) {
          MT p = static_cast<MT>(param_vec[j]) - ratio * trust_ratio_div_vec[j];
          param_vec[j] = static_cast<ParamT>(p);
        }
        phi::Store(param_vec, param + i);
      }
    }

    for (; i < size; ++i) {
      if (HasMasterParam) {
        MT p = master_param[i] - ratio * trust_ratio_div[i];
        master_param[i] = p;
        param[i] = static_cast<ParamT>(p);
      } else {
        MT p = static_cast<MT>(param[i]) - ratio * trust_ratio_div[i];
        param[i] = static_cast<ParamT>(p);
      }
    }

    if (NeedUpdateBetaPow && threadIdx.x == 0 && blockIdx.x == 0) {
      betapow_helper.UpdateBetaPows();
    }
  }
};

// TODO(zengjinle): which block_dim and chunk_size would be better?
template <typename ParamT,
          int MaxTensorNumPerLaunch = 160,
          int MaxChunkNumPerLaunch = 780>
static void MultiTensorUpdateLambParamAndBetaPows(
    const phi::GPUContext &dev_ctx,
    const int *offsets,
    int n,
    const MasterT<ParamT> *trust_ratio_div,
    const MasterT<ParamT> *lr,
    const MasterT<ParamT> *param_square_norm,
    const MasterT<ParamT> *trust_ratio_div_square_norm,
    const bool *found_inf,
    ParamT *param,
    MasterT<ParamT> *master_param,
    MasterT<ParamT> *beta1pow,
    MasterT<ParamT> *beta2pow,
    MasterT<ParamT> beta1,
    MasterT<ParamT> beta2,
    int chunk_size = 65536) {
  constexpr bool kHasMasterParam =
      !(std::is_same<ParamT, MasterT<ParamT>>::value);

  bool has_beta_pow = (beta1pow != nullptr);
  if (has_beta_pow) {
    PADDLE_ENFORCE_NOT_NULL(
        beta2pow,
        phi::errors::InvalidArgument("Beta2Pow should not be nullptr."));
  } else {
    PADDLE_ENFORCE_EQ(
        beta2pow,
        nullptr,
        phi::errors::InvalidArgument("Beta2Pow should be nullptr."));
  }

  const int block_dim = 512;

  int vec_size = 8;
  for (int i = 0; i < n; ++i) {
    int offset = offsets[i] - offsets[0];
    vec_size =
        std::min(vec_size, GetChunkedVecSize(param + offset, chunk_size));
    if (kHasMasterParam) {
      vec_size = std::min(vec_size,
                          GetChunkedVecSize(master_param + offset, chunk_size));
    }
    vec_size = std::min(
        vec_size, GetChunkedVecSize(trust_ratio_div + offset, chunk_size));
  }

  VLOG(1) << __func__ << " VecSize = " << vec_size;

  constexpr auto kNumTensor = MaxTensorNumPerLaunch;
  constexpr auto kNumChunk = MaxChunkNumPerLaunch;

  auto stream = dev_ctx.stream();
#define PD_LAUNCH_MULTI_TENSOR_UPDATE_PARAM_BETAPOW(__has_beta_pow)      \
  do {                                                                   \
    using FunctorT = LambUpdateParamAndBetaPowsFunctor<ParamT,           \
                                                       kHasMasterParam,  \
                                                       __has_beta_pow,   \
                                                       kVecSize>;        \
    LambParamHelper<ParamT, kHasMasterParam> param_helper(param,         \
                                                          master_param); \
    LambBetaPowUpdateOnceHelper<MasterT<ParamT>, __has_beta_pow>         \
        betapow_helper(beta1pow, beta2pow, beta1, beta2);                \
    launcher.Launch(FunctorT(),                                          \
                    param_helper,                                        \
                    trust_ratio_div,                                     \
                    lr,                                                  \
                    param_square_norm,                                   \
                    trust_ratio_div_square_norm,                         \
                    found_inf,                                           \
                    betapow_helper);                                     \
  } while (0)

#define PD_LAUNCH_VEC_MULTI_TENSOR_UPDATE_PARAM_BETAPOW_CASE                   \
  do {                                                                         \
    auto callback =                                                            \
        [&](const paddle::operators::MultiTensorLauncher<kNumTensor,           \
                                                         kNumChunk> &launcher, \
            int launch_n) {                                                    \
          if (has_beta_pow && launch_n == 0) {                                 \
            PD_LAUNCH_MULTI_TENSOR_UPDATE_PARAM_BETAPOW(true);                 \
            beta1pow = nullptr;                                                \
            beta2pow = nullptr;                                                \
          } else {                                                             \
            PD_LAUNCH_MULTI_TENSOR_UPDATE_PARAM_BETAPOW(false);                \
          }                                                                    \
        };                                                                     \
    paddle::operators::MultiTensorApplyWithCallback<kNumTensor, kNumChunk>(    \
        stream, offsets, n, chunk_size, block_dim, callback);                  \
  } while (0)

  PD_VEC_LAUNCH_KERNEL(vec_size,
                       PD_LAUNCH_VEC_MULTI_TENSOR_UPDATE_PARAM_BETAPOW_CASE);

#undef PD_LAUNCH_MULTI_TENSOR_UPDATE_PARAM_BETAPOW
#undef PD_LAUNCH_VEC_MULTI_TENSOR_UPDATE_PARAM_BETAPOW_CASE
}

#if defined(PADDLE_WITH_NCCL) || defined(PADDLE_WITH_RCCL)
static bool CreatePreMulScaleOpIfSupported(
    ncclDataType_t dtype,
    ncclComm_t comm,
    const void *scale,
    ncclRedOp_t *op,
    distributed::NCCLCommContext *comm_ctx = nullptr) {
#if NCCL_VERSION_CODE >= 21100
  if (FLAGS_dynamic_static_unified_comm) {
    PADDLE_ENFORCE_NOT_NULL(
        comm_ctx,
        phi::errors::InvalidArgument(
            "You choose to use new communication library by "
            "setting environment "
            "variable FLAGS_dynamic_static_unified_comm True. "
            "But parameter of comm_ctx should not be nullptr."));
    int ver = comm_ctx->GetNcclVersion();
    if (ver >= 21100) {
      VLOG(10) << "ncclRedOpCreatePreMulSum is supported.";
      comm_ctx->RedOpCreatePreMulSum(
          op, const_cast<void *>(scale), dtype, ncclScalarDevice);
      return true;
    }
  } else {
    int ver;
    PADDLE_ENFORCE_GPU_SUCCESS(phi::dynload::ncclGetVersion(&ver));
    if (ver >= 21100) {
      VLOG(10) << "ncclRedOpCreatePreMulSum is supported.";
      PADDLE_ENFORCE_GPU_SUCCESS(phi::dynload::ncclRedOpCreatePreMulSum(
          op, const_cast<void *>(scale), dtype, ncclScalarDevice, comm));
      return true;
    }
  }
#endif
  VLOG(10) << "ncclRedOpCreatePreMulSum is not supported.";
  return false;
}

static void DestoryOpIfSupported(
    ncclRedOp_t op,
    ncclComm_t comm,
    distributed::NCCLCommContext *comm_ctx = nullptr) {
#if NCCL_VERSION_CODE >= 21100
  VLOG(10) << "ncclRedOpDestroy starts";

  if (FLAGS_dynamic_static_unified_comm) {
    PADDLE_ENFORCE_NOT_NULL(
        comm_ctx,
        phi::errors::InvalidArgument(
            "You choose to use new communication library by "
            "setting environment "
            "variable FLAGS_dynamic_static_unified_comm True. "
            "But parameter of comm_ctx should not be nullptr."));
    comm_ctx->RedOpDestroy(op);
  } else {
    PADDLE_ENFORCE_GPU_SUCCESS(phi::dynload::ncclRedOpDestroy(op, comm));
  }
  VLOG(10) << "ncclRedOpDestroy ends";

#endif
  VLOG(10) << "ncclRedOpDestroy is not supported.";
}

template <typename T1, typename T2>
static void LaunchScaleKernel(const phi::GPUContext &dev_ctx,
                              const T1 *x,
                              const T2 *scale,
                              T1 *y,
                              int n,
                              gpuStream_t stream) {
  int vec_size = std::min(GetChunkedVecSize(x, 0), GetChunkedVecSize(y, 0));
  auto config = phi::backends::gpu::GetGpuLaunchConfig1D(dev_ctx, n, vec_size);

#define PD_LAMB_VEC_SCALE_KERNEL_CASE                                    \
  do {                                                                   \
    ScaleCUDAKernel<T1, T2, kVecSize>                                    \
        <<<config.block_per_grid, config.thread_per_block, 0, stream>>>( \
            x, scale, y, n);                                             \
  } while (0)

  PD_VEC_LAUNCH_KERNEL(vec_size, PD_LAMB_VEC_SCALE_KERNEL_CASE);
#undef PD_LAMB_VEC_SCALE_KERNEL_CASE
}

template <typename T, bool UseReduceScatter>
static void NCCLSumWithScaleBase(const T *sendbuff,
                                 T *recvbuff,
                                 size_t recvcount,
                                 size_t nranks,
                                 ncclComm_t comm,
                                 gpuStream_t stream,
                                 const phi::GPUContext &dev_ctx,
                                 distributed::NCCLCommContext *comm_ctx,
                                 const T *scale = nullptr) {
  if (FLAGS_dynamic_static_unified_comm) {
    PADDLE_ENFORCE_NOT_NULL(
        comm_ctx,
        phi::errors::InvalidArgument(
            "You choose to use new communication library by "
            "setting environment "
            "variable FLAGS_dynamic_static_unified_comm True. "
            "But parameter of comm_ctx should not be nullptr."));
  }

  static_assert(
      std::is_same<T, float>::value || std::is_same<T, dtype::float16>::value,
      "T must be either float32 or float16.");
  if (recvcount == 0) return;

  auto numel = UseReduceScatter ? (recvcount * nranks) : recvcount;
  if (comm == nullptr) {
    if (scale != nullptr) {
      PADDLE_ENFORCE_EQ(nranks,
                        1,
                        phi::errors::InvalidArgument(
                            "nranks must be 1 when scale != nullptr."));
      LaunchScaleKernel(dev_ctx, sendbuff, scale, recvbuff, numel, stream);
    }
    return;
  }

  ncclRedOp_t op = ncclSum;
  ncclDataType_t dtype =
      std::is_same<T, float>::value ? ncclFloat32 : ncclFloat16;
  bool should_destroy_op = scale && CreatePreMulScaleOpIfSupported(
                                        dtype, comm, scale, &op, comm_ctx);
  memory_utils::Buffer buffer(dev_ctx.GetPlace());
  if (scale && !should_destroy_op) {
    T *new_sendbuff = buffer.Alloc<T>(numel);
    LaunchScaleKernel(dev_ctx, sendbuff, scale, new_sendbuff, numel, stream);
    sendbuff = new_sendbuff;
  }

  if (comm_ctx) {
    // Here assume comm_ctx->GetNcclComm() have higher priority than comm
    if (UseReduceScatter) {
      // TODO(BeingGod): NCCLCommContext::ReduceScatter only accept DenseTensor,
      // but sendbuff or recvbuff maybe allocated by Buffer.
      PADDLE_ENFORCE_GPU_SUCCESS(
          phi::dynload::ncclReduceScatter(sendbuff,
                                          recvbuff,
                                          recvcount,
                                          dtype,
                                          op,
                                          comm_ctx->GetNcclComm(),
                                          stream));
    } else {
      // TODO(BeingGod): NCCLCommContext::AllReduce only accept DenseTensor,
      // but sendbuff or recvbuff maybe allocated by Buffer.
      PADDLE_ENFORCE_GPU_SUCCESS(
          phi::dynload::ncclAllReduce(sendbuff,
                                      recvbuff,
                                      recvcount,
                                      dtype,
                                      op,
                                      comm_ctx->GetNcclComm(),
                                      stream));
    }
  } else {
    if (UseReduceScatter) {
      PADDLE_ENFORCE_GPU_SUCCESS(phi::dynload::ncclReduceScatter(
          sendbuff, recvbuff, recvcount, dtype, op, comm, stream));
    } else {
      PADDLE_ENFORCE_GPU_SUCCESS(phi::dynload::ncclAllReduce(
          sendbuff, recvbuff, recvcount, dtype, op, comm, stream));
    }
  }

  if (should_destroy_op) {
    DestoryOpIfSupported(op, comm, comm_ctx);
  }
}

template <typename T>
static void NCCLReduceScatterWithScale(const T *sendbuff,
                                       T *recvbuff,
                                       size_t recvcount,
                                       size_t nranks,
                                       ncclComm_t comm,
                                       gpuStream_t stream,
                                       const phi::GPUContext &dev_ctx,
                                       distributed::NCCLCommContext *comm_ctx,
                                       const T *scale = nullptr) {
  NCCLSumWithScaleBase<T, true>(sendbuff,
                                recvbuff,
                                recvcount,
                                nranks,
                                comm,
                                stream,
                                dev_ctx,
                                comm_ctx,
                                scale);
}

template <typename T>
static void NCCLAllReduceWithScale(const T *sendbuff,
                                   T *recvbuff,
                                   size_t recvcount,
                                   size_t nranks,
                                   ncclComm_t comm,
                                   gpuStream_t stream,
                                   const phi::GPUContext &dev_ctx,
                                   distributed::NCCLCommContext *comm_ctx,
                                   const T *scale = nullptr) {
  NCCLSumWithScaleBase<T, false>(sendbuff,
                                 recvbuff,
                                 recvcount,
                                 nranks,
                                 comm,
                                 stream,
                                 dev_ctx,
                                 comm_ctx,
                                 scale);
}

#endif

template <typename InputIteratorT,
          typename OutputIteratorT,
          typename ReduceOpT,
          typename T>
static void CubDeviceReduce(InputIteratorT d_in,
                            OutputIteratorT d_out,
                            int num_items,
                            ReduceOpT reduction_op,
                            T init,
                            gpuStream_t stream,
                            memory_utils::Buffer *buffer) {
  void *d_temp_storage = nullptr;
  size_t temp_storage_bytes = 0;
  PADDLE_ENFORCE_GPU_SUCCESS(cub::DeviceReduce::Reduce(d_temp_storage,
                                                       temp_storage_bytes,
                                                       d_in,
                                                       d_out,
                                                       num_items,
                                                       reduction_op,
                                                       init,
                                                       stream));
  d_temp_storage = buffer->Alloc<void>(temp_storage_bytes);
  VLOG(10) << "cub::DeviceReduce::Reduce needs " << temp_storage_bytes
           << " byte(s), ptr = " << d_temp_storage;
  PADDLE_ENFORCE_GPU_SUCCESS(cub::DeviceReduce::Reduce(d_temp_storage,
                                                       temp_storage_bytes,
                                                       d_in,
                                                       d_out,
                                                       num_items,
                                                       reduction_op,
                                                       init,
                                                       stream));
}

template <typename T>
static void GetSquareGradNormImpl(const T *grad,
                                  int n,
                                  float *square_norm,
                                  gpuStream_t stream,
                                  memory_utils::Buffer *cub_tmp_buffer) {
  using Iterator =
      cub::TransformInputIterator<float, SquareFunctor<T>, const T *>;
  Iterator iter(grad, SquareFunctor<T>());
  CubDeviceReduce(iter,
                  square_norm,
                  n,
                  cub::Sum(),
                  static_cast<float>(0),
                  stream,
                  cub_tmp_buffer);
}

// square_norm is of length 2 at least
static void GetSquareGradNorm(const float *fp32_grad,
                              int fp32_numel,
                              const dtype::float16 *fp16_grad,
                              int fp16_numel,
                              float *square_norm,
                              gpuStream_t stream,
                              memory_utils::Buffer *cub_tmp_buffer) {
  VLOG(10) << "GetSquareGradNorm starts, fp32_numel = " << fp32_numel
           << " , fp16_numel = " << fp16_numel;
  if (fp32_numel > 0) {
    GetSquareGradNormImpl(
        fp32_grad, fp32_numel, square_norm, stream, cub_tmp_buffer);
    VLOG(10) << "FP32 square L2-Norm: "
             << FlattenToString(square_norm, 1, cub_tmp_buffer->GetPlace());
  }

  if (fp16_numel > 0) {
    float *fp16_square_norm = fp32_numel > 0 ? square_norm + 1 : square_norm;
    GetSquareGradNormImpl(
        fp16_grad, fp16_numel, fp16_square_norm, stream, cub_tmp_buffer);
    VLOG(10) << "FP16 square L2-Norm: "
             << FlattenToString(
                    fp16_square_norm, 1, cub_tmp_buffer->GetPlace());
    if (fp32_numel > 0) {
      AddToCUDAKernel<<<1, 1, 0, stream>>>(fp16_square_norm, square_norm);
      VLOG(10) << "FP32+FP16 square L2-Norm: "
               << FlattenToString(square_norm, 1, cub_tmp_buffer->GetPlace());
    }
  }
  VLOG(10) << "GetSquareGradNorm ends, fp32_numel = " << fp32_numel
           << " , fp16_numel = " << fp16_numel;
}

template <typename T>
std::string NumToString(T x) {
  std::stringstream ss;
  ss << x;
  return ss.str();
}

template <typename T>
static std::string GetMinMaxStr(const T *x, size_t n, const phi::Place &place) {
  PADDLE_ENFORCE_EQ(
      place.GetType() == phi::AllocationType::GPU,
      true,
      phi::errors::InvalidArgument("Only support CUDAPlace currently."));

  auto *dev_ctx = static_cast<phi::GPUContext *>(
      phi::DeviceContextPool::Instance().Get(place));
  auto stream = dev_ctx->stream();

  memory_utils::Buffer ret_buffer(place);
  T *ret = ret_buffer.Alloc<T>(2);

  if (n > 0) {
    memory_utils::Buffer cub_buffer(place);
    CubDeviceReduce(x,
                    ret,
                    n,
                    cub::Min(),
                    std::numeric_limits<T>::max(),
                    stream,
                    &cub_buffer);
    CubDeviceReduce(x,
                    ret + 1,
                    n,
                    cub::Max(),
                    std::numeric_limits<T>::lowest(),
                    stream,
                    &cub_buffer);
    T ret_cpu[2];
#ifdef PADDLE_WITH_HIP
    PADDLE_ENFORCE_GPU_SUCCESS(hipMemcpyAsync(
        &ret_cpu[0], ret, 2 * sizeof(T), hipMemcpyDeviceToHost, stream));
    PADDLE_ENFORCE_GPU_SUCCESS(hipStreamSynchronize(stream));
#else
    PADDLE_ENFORCE_GPU_SUCCESS(cudaMemcpyAsync(
        &ret_cpu[0], ret, 2 * sizeof(T), cudaMemcpyDeviceToHost, stream));
    PADDLE_ENFORCE_GPU_SUCCESS(cudaStreamSynchronize(stream));
#endif
    return std::string("{\"min\": ") + NumToString(ret_cpu[0]) +
           " , \"max\": " + NumToString(ret_cpu[1]) + "}";
  } else {
    return "{\"min\": null, \"max\": null}";
  }
}

struct VisitDTypeFunctor {
  VisitDTypeFunctor(const phi::DenseTensor *x, std::string *s) : x_(x), s_(s) {}

  template <typename T>
  void apply() const {
    *s_ = GetMinMaxStr<T>(x_->template data<T>(), x_->numel(), x_->place());
  }

 private:
  const phi::DenseTensor *x_;
  std::string *s_;
};

static std::string GetMinMaxStr(const phi::DenseTensor *x) {
  if (x == nullptr) return "null";
  if (!x->initialized()) return "not_inited";
  if (x->place().GetType() != phi::AllocationType::GPU) return "CPUTensor";
  std::string str;
  VisitDTypeFunctor functor(x, &str);
  phi::VisitDataType(x->dtype(), functor);
  return str;
}

template <typename T>
static bool HasNanInf(const phi::GPUContext &dev_ctx, const T *x, int numel) {
  if (numel <= 0) return false;
  cub::TransformInputIterator<bool, IsNanInfFunctor<T>, const T *> iter(
      x, IsNanInfFunctor<T>());
  memory_utils::Buffer buffer(dev_ctx.GetPlace());
  memory_utils::Buffer out(dev_ctx.GetPlace());
  CubDeviceReduce(iter,
                  out.Alloc<bool>(1),
                  numel,
                  OrFunctor(),
                  false,
                  dev_ctx.stream(),
                  &buffer);
  bool flag;
#ifdef PADDLE_WITH_HIP
  PADDLE_ENFORCE_GPU_SUCCESS(hipMemcpyAsync(&flag,
                                            out.Get<bool>(),
                                            sizeof(flag),
                                            hipMemcpyDeviceToHost,
                                            dev_ctx.stream()));
#else
  PADDLE_ENFORCE_GPU_SUCCESS(cudaMemcpyAsync(&flag,
                                             out.Get<bool>(),
                                             sizeof(flag),
                                             cudaMemcpyDeviceToHost,
                                             dev_ctx.stream()));
#endif
  dev_ctx.Wait();
  return flag;
}

static void CheckHasNanInfGrad(const float *fp32_grad,
                               int fp32_numel,
                               const dtype::float16 *fp16_grad,
                               int fp16_numel,
                               float *nan_inf_flag,
                               gpuStream_t stream,
                               memory_utils::Buffer *cub_tmp_buffer) {
  bool *fp32_has_nan_inf = nullptr;
  bool *fp16_has_nan_inf = nullptr;
  if (fp32_numel > 0) {
    fp32_has_nan_inf = reinterpret_cast<bool *>(nan_inf_flag + 1);
    cub::TransformInputIterator<bool, IsNanInfFunctor<float>, const float *>
        iter(fp32_grad, IsNanInfFunctor<float>());
    CubDeviceReduce(iter,
                    fp32_has_nan_inf,
                    fp32_numel,
                    OrFunctor(),
                    false,
                    stream,
                    cub_tmp_buffer);
  }

  if (fp16_numel > 0) {
    fp16_has_nan_inf = reinterpret_cast<bool *>(nan_inf_flag + 1) + 1;
    cub::TransformInputIterator<bool,
                                IsNanInfFunctor<dtype::float16>,
                                const dtype::float16 *>
        iter(fp16_grad, IsNanInfFunctor<dtype::float16>());
    CubDeviceReduce(iter,
                    fp16_has_nan_inf,
                    fp16_numel,
                    OrFunctor(),
                    false,
                    stream,
                    cub_tmp_buffer);
  }

  if (fp32_has_nan_inf && fp16_has_nan_inf) {
    SetNanInfValueCUDAKernelTwoFlag<<<1, 1, 0, stream>>>(
        fp32_has_nan_inf, fp16_has_nan_inf, nan_inf_flag);
  } else if (fp32_has_nan_inf) {
    SetNanInfValueCUDAKernelOneFlag<<<1, 1, 0, stream>>>(fp32_has_nan_inf,
                                                         nan_inf_flag);
  } else {
    SetNanInfValueCUDAKernelOneFlag<<<1, 1, 0, stream>>>(fp16_has_nan_inf,
                                                         nan_inf_flag);
  }
}

template <typename T1, typename T2, typename T3, int VecSize>
static __global__ void ElementwiseAddWithCastCUDAKernel(const T1 *x,
                                                        const T2 *y,
                                                        T3 *z,
                                                        int n) {
  static_assert(sizeof(T1) <= sizeof(T2),
                "sizeof(T1) must be smaller than sizeof(T2).");
  using MT = MasterT<T2>;

  int i = (threadIdx.x + blockIdx.x * blockDim.x) * VecSize;
  int stride = (blockDim.x * gridDim.x) * VecSize;
  for (; i + VecSize <= n; i += stride) {
    phi::AlignedVector<T1, VecSize> x_vec;
    phi::AlignedVector<T2, VecSize> y_vec;
    phi::AlignedVector<T3, VecSize> z_vec;
    phi::Load(x + i, &x_vec);
    phi::Load(y + i, &y_vec);
#pragma unroll
    for (int j = 0; j < VecSize; ++j) {
      auto x_tmp = static_cast<MT>(x_vec[j]);
      auto y_tmp = static_cast<MT>(y_vec[j]);
      z_vec[j] = static_cast<T3>(x_tmp + y_tmp);
    }
    phi::Store(z_vec, z + i);
  }

  for (; i < n; ++i) {
    auto x_tmp = static_cast<MT>(x[i]);
    auto y_tmp = static_cast<MT>(y[i]);
    z[i] = static_cast<T3>(x_tmp + y_tmp);
  }
}

template <typename T1, typename T2, typename T3>
static void LaunchElementwiseAddWithCastKernel(const phi::GPUContext &dev_ctx,
                                               const T1 *x,
                                               const T2 *y,
                                               T3 *z,
                                               int n,
                                               gpuStream_t stream) {
  int vec_size =
      std::min(std::min(GetChunkedVecSize(x, 0), GetChunkedVecSize(y, 0)),
               GetChunkedVecSize(z, 0));
  auto config = phi::backends::gpu::GetGpuLaunchConfig1D(dev_ctx, n, vec_size);

#define PD_LAUNCH_ELEMENTWISE_ADD_WITH_CAST_KERNEL                       \
  do {                                                                   \
    ElementwiseAddWithCastCUDAKernel<T1, T2, T3, kVecSize>               \
        <<<config.block_per_grid, config.thread_per_block, 0, stream>>>( \
            x, y, z, n);                                                 \
  } while (0)

  PD_VEC_LAUNCH_KERNEL(vec_size, PD_LAUNCH_ELEMENTWISE_ADD_WITH_CAST_KERNEL);
#undef PD_LAUNCH_ELEMENTWISE_ADD_WITH_CAST_KERNEL
}

template <typename T, typename Context>
void DistributedFusedLambKernel(
    const Context &dev_ctx,
    const std::vector<const DenseTensor *> &param,
    const std::vector<const DenseTensor *> &grad, /*unused*/
    const paddle::optional<DenseTensor> &fp32_param,
    const paddle::optional<DenseTensor> &fp32_grad,
    const paddle::optional<DenseTensor> &fp16_param,
    const paddle::optional<DenseTensor> &fp16_grad,
    const DenseTensor &moment1,
    const DenseTensor &moment2,
    const DenseTensor &beta1_pow,
    const DenseTensor &beta2_pow,
    const DenseTensor &param_offsets,
    const DenseTensor &fp32_partial_offsets,
    const DenseTensor &fp16_partial_offsets,
    const DenseTensor &param_info,
    const DenseTensor &param_order,
    const DenseTensor &learning_rate,
    const DenseTensor &global_scale,
    int acc_steps,
    float beta1,
    float beta2,
    float epsilon,
    float max_global_grad_norm,
    float weight_decay,
    bool clip_after_allreduce,
    bool use_master_param_norm,
    bool use_master_acc_grad,
    bool is_grad_scaled_by_nranks,
    bool use_hierarchical_allreduce,
    int64_t nranks,
    const std::vector<int> &ring_ids,
    DenseTensor *fp32_param_out,
    DenseTensor *fp16_param_out,
    DenseTensor *fp32_acc_grad,
    DenseTensor *fp16_acc_grad,
    DenseTensor *moment1_out,
    DenseTensor *moment2_out,
    DenseTensor *beta1_pow_out,
    DenseTensor *beta2_pow_out,
    DenseTensor *param_out, /*unused*/
    DenseTensor *found_inf,
    DenseTensor *acc_step,
    DenseTensor *stop_update,
    DenseTensor *step) {
#if defined(PADDLE_WITH_NCCL) || defined(PADDLE_WITH_RCCL)
  auto stream = dev_ctx.stream();
  auto place = dev_ctx.GetPlace();
  found_inf->Resize({1});
  // Step 1: Get fp16 param and grad tensors
  int64_t fp16_numel;
  auto *fp16_param_data =
      GetSameInOutTensorPtr<dtype::float16, Context, true>(dev_ctx,
                                                           fp16_param.get_ptr(),
                                                           fp16_param_out,
                                                           "FP16FusedParam",
                                                           "FP16FusedParamOut",
                                                           &fp16_numel);
  bool has_fp16_param = (fp16_numel > 0);
  const dtype::float16 *fp16_grad_data = nullptr;
  if (has_fp16_param) {
    fp16_grad_data =
        GetInputTensorPtr<dtype::float16>(fp16_grad.get_ptr(), "FP16FusedGrad");
  } else {
    fp16_param_data = nullptr;
  }
  // Step 2: Get fp32 param and grad tensors
  int64_t fp32_numel = 0;
  auto *fp32_param_data =
      GetSameInOutTensorPtr<float, Context, true>(dev_ctx,
                                                  fp32_param.get_ptr(),
                                                  fp32_param_out,
                                                  "FP32FusedParam",
                                                  "FP32FusedParamOut",
                                                  &fp32_numel);
  PADDLE_ENFORCE_GE(fp32_numel,
                    fp16_numel,
                    phi::errors::InvalidArgument(
                        "The element number in FP32FusedParam should be not "
                        "less than FP16FusedParam."));
  fp32_numel -= fp16_numel;  // the FP32FusedParam contains fp32 param and
                             // fp16 master weight
  bool has_fp32_param = (fp32_numel > 0);
  const float *fp32_grad_data = nullptr;
  if (has_fp32_param) {
    fp32_grad_data =
        GetInputTensorPtr<float>(fp32_grad.get_ptr(), "FP32FusedGrad");
  } else {
    PADDLE_ENFORCE_EQ(
        has_fp16_param,
        true,
        phi::errors::InvalidArgument(
            "Either FP32FusedGrad or FP16FusedGrad cannot be NULL."));
  }
  auto numel = fp32_numel + fp16_numel;
  VLOG(1) << "numel = " << numel << " , fp32_numel = " << fp32_numel
          << " , fp16_numel = " << fp16_numel;

  // The NVIDIA cub library does not support number > INT32_MAX
  PADDLE_ENFORCE_LE(numel,
                    std::numeric_limits<int>::max(),
                    phi::errors::Unimplemented(
                        "Too many parameter number. Only <= %d is supported.",
                        std::numeric_limits<int>::max()));

  PADDLE_ENFORCE_GE(
      acc_steps,
      1,
      phi::errors::InvalidArgument(
          "The gradient accumulation steps should be not less than 1."));
  if (acc_steps > 1) {
    PADDLE_ENFORCE_NOT_NULL(
        acc_step,
        phi::errors::InvalidArgument(
            "Output(AccStep) cannot be nullptr when Attr(acc_steps) > 1."));
    bool is_initialized = acc_step->initialized();
    int64_t *acc_step_data;
    if (is_initialized) {
      acc_step_data = dev_ctx.template HostAlloc<int64_t>(acc_step);
      ++(*acc_step_data);
    } else {
      acc_step->Resize({1});
      acc_step_data = dev_ctx.template HostAlloc<int64_t>(acc_step);
      *acc_step_data = 1;
    }
    int64_t rounded_step = (*acc_step_data) % acc_steps;
    float *fp32_acc_grad_data = nullptr;
    if (has_fp32_param) {
      PADDLE_ENFORCE_NOT_NULL(fp32_acc_grad,
                              phi::errors::InvalidArgument(
                                  "Output(FP32AccFusedGrad) cannot be nullptr "
                                  "when Attr(acc_steps) > 1."));
      if (!fp32_acc_grad->initialized()) {
        fp32_acc_grad->Resize({static_cast<int64_t>(fp32_numel)});
        fp32_acc_grad_data = dev_ctx.template Alloc<float>(fp32_acc_grad);
      } else {
        fp32_acc_grad_data = fp32_acc_grad->data<float>();
      }
    }

    dtype::float16 *fp16_acc_grad_data = nullptr;
    float *master_acc_grad = nullptr;
    if (has_fp16_param) {
      PADDLE_ENFORCE_NOT_NULL(fp16_acc_grad,
                              phi::errors::InvalidArgument(
                                  "Output(FP16AccFusedGrad) cannot be nullptr "
                                  "when Attr(acc_steps) > 1."));
      if (!fp16_acc_grad->initialized()) {
        auto acc_grad_size =
            use_master_acc_grad ? (3 * fp16_numel) : fp16_numel;
        fp16_acc_grad->Resize({static_cast<int64_t>(acc_grad_size)});
        fp16_acc_grad_data =
            dev_ctx.template Alloc<dtype::float16>(fp16_acc_grad);
      } else {
        fp16_acc_grad_data = fp16_acc_grad->data<dtype::float16>();
      }
      if (use_master_acc_grad) {
        master_acc_grad =
            reinterpret_cast<float *>(fp16_acc_grad_data + fp16_numel);
      }
    } else {
      use_master_acc_grad = false;
    }

    // Inplace addto
    if (has_fp32_param) {
      if (rounded_step == 1) {
        memory_utils::Copy(place,
                           fp32_acc_grad_data,
                           place,
                           fp32_grad_data,
                           fp32_numel * sizeof(float),
                           stream);
      } else {
        LaunchElementwiseAddWithCastKernel(dev_ctx,
                                           fp32_grad_data,
                                           fp32_acc_grad_data,
                                           fp32_acc_grad_data,
                                           fp32_numel,
                                           stream);
      }
    }

    if (has_fp16_param) {
      if (acc_steps == 2 || !use_master_acc_grad) {
        if (rounded_step != 1) {
          LaunchElementwiseAddWithCastKernel(dev_ctx,
                                             fp16_acc_grad_data,
                                             fp16_grad_data,
                                             fp16_acc_grad_data,
                                             fp16_numel,
                                             stream);
        } else {
          memory_utils::Copy(place,
                             fp16_acc_grad_data,
                             place,
                             fp16_grad_data,
                             fp16_numel * sizeof(dtype::float16),
                             stream);
        }
      } else {  // acc_steps >= 3
        if (rounded_step == 0) {
          LaunchElementwiseAddWithCastKernel(dev_ctx,
                                             fp16_grad_data,
                                             master_acc_grad,
                                             fp16_acc_grad_data,
                                             fp16_numel,
                                             stream);
        } else if (rounded_step == 1) {
          memory_utils::Copy(place,
                             fp16_acc_grad_data,
                             place,
                             fp16_grad_data,
                             fp16_numel * sizeof(dtype::float16),
                             stream);
        } else if (rounded_step == 2) {
          LaunchElementwiseAddWithCastKernel(dev_ctx,
                                             fp16_grad_data,
                                             fp16_acc_grad_data,
                                             master_acc_grad,
                                             fp16_numel,
                                             stream);
        } else {
          LaunchElementwiseAddWithCastKernel(dev_ctx,
                                             fp16_grad_data,
                                             master_acc_grad,
                                             master_acc_grad,
                                             fp16_numel,
                                             stream);
        }
      }
    }
    stop_update->Resize({1});
    auto *stop_update_data = dev_ctx.template HostAlloc<bool>(stop_update);
    auto *found_inf_cpu = dev_ctx.template HostAlloc<bool>(found_inf);
    if (rounded_step != 0) {
      *stop_update_data = true;
      *found_inf_cpu = false;
      return;
    } else {
      // swap pointer
      fp32_grad_data = fp32_acc_grad_data;
      fp16_grad_data = fp16_acc_grad_data;
      *stop_update_data = false;
      found_inf->clear();
    }
  }

  // Step 3: Get ParamInfo
  const auto *param_info_data =
      GetInputTensorPtr<int>(&param_info, "ParamInfo");
  auto fp32_local_start_idx = param_info_data[0];
  auto fp32_local_param_num = param_info_data[1];
  auto fp32_global_param_num = param_info_data[2];
  auto fp32_weight_decay_end_idx = param_info_data[3];
  auto fp16_local_start_idx = param_info_data[4];
  auto fp16_local_param_num = param_info_data[5];
  auto fp16_global_param_num = param_info_data[6];
  auto fp16_weight_decay_end_idx = param_info_data[7];

  auto local_param_num = fp32_local_param_num + fp16_local_param_num;
  auto param_num = fp32_global_param_num + fp16_global_param_num;
  PADDLE_ENFORCE_LE(local_param_num,
                    param_num,
                    phi::errors::InvalidArgument(
                        "The local parameter number should not exceed the "
                        "global parameter number."));
  VLOG(1) << "local_param_num = " << local_param_num
          << " , global_param_num = " << param_num
          << " , fp32_local_start_idx = " << fp32_local_start_idx
          << " , fp32_local_param_num = " << fp32_local_param_num
          << " , fp32_global_param_num = " << fp32_global_param_num
          << " , fp16_local_start_idx = " << fp16_local_start_idx
          << " , fp16_local_param_num = " << fp16_local_param_num
          << " , fp16_global_param_num = " << fp16_global_param_num;

  // Step 4: Get LearningRate, Moment1, Moment2, Beta1Pow, Beta2Pow,
  // GlobalScale
  const auto *global_scale_data =
      GetInputTensorPtr<float>(&global_scale, "GlobalScale");
  const auto *lr_data =
      GetInputTensorPtr<float>(&learning_rate, "LearningRate");
  int64_t partial_numel = 0;
  auto *moment1_data = GetSameInOutTensorPtr<float, Context>(
      dev_ctx, &moment1, moment1_out, "Moment1", "Moment1Out", &partial_numel);
  PADDLE_ENFORCE_EQ(numel % partial_numel,
                    0,
                    phi::errors::InvalidArgument(
                        "The total parameter number %d should be divided "
                        "exactly by the element number %d of Moment1.",
                        numel,
                        partial_numel));

  // The num_devices means the number of devices that shard a complete set
  // of all parameters. It may be num_devices < nranks or num_devices ==
  // nranks.
  int64_t num_devices = numel / partial_numel;
  VLOG(1) << "num_devices = " << num_devices
          << " , partial_numel = " << partial_numel;

  PADDLE_ENFORCE_EQ(fp32_numel % num_devices,
                    0,
                    phi::errors::InvalidArgument(
                        "The fp32 parameter number %d should be divided "
                        "exactly by the device number %d.",
                        fp32_numel,
                        num_devices));
  PADDLE_ENFORCE_EQ(fp16_numel % num_devices,
                    0,
                    phi::errors::InvalidArgument(
                        "The fp16 parameter number %d should be divided "
                        "exactly by the device number %d.",
                        fp16_numel,
                        num_devices));
  auto *moment2_data = GetSameInOutTensorPtr<float, Context>(
      dev_ctx, &moment2, moment2_out, "Moment2", "Moment2Out");
  auto *beta1_pow_data = GetSameInOutTensorPtr<float, Context>(
      dev_ctx, &beta1_pow, beta1_pow_out, "Beta1Pow", "Beta1PowOut");
  auto *beta2_pow_data = GetSameInOutTensorPtr<float, Context>(
      dev_ctx, &beta2_pow, beta2_pow_out, "Beta2Pow", "Beta2PowOut");
  auto *found_inf_data = dev_ctx.template Alloc<bool>(found_inf);
  // Step 5: Get attributes weight_decay, beta1, beta2, epsilon,
  // max_grad_norm, ring_id,
  // use_master_param_norm, is_grad_scaled_by_nranks
  PADDLE_ENFORCE_GE(nranks,
                    num_devices,
                    phi::errors::InvalidArgument(
                        "The nranks must be not less than num_devices."));
  PADDLE_ENFORCE_EQ(nranks % num_devices,
                    0,
                    phi::errors::InvalidArgument(
                        "The nranks must be exactly divided by num_devices."));
  bool local_shard = (nranks > num_devices);

  VLOG(10) << "max_global_grad_norm = " << max_global_grad_norm
           << " , clip_after_allreduce = " << clip_after_allreduce
           << " , use_master_param_norm = " << use_master_param_norm
           << " , is_grad_scaled_by_nranks = " << is_grad_scaled_by_nranks
           << " , local_shard = " << local_shard
           << " , use_hierarchical_allreduce = " << use_hierarchical_allreduce;

  // Step 6: allreduce + global norm gradient clip
  int64_t global_rank = 0, local_rank = 0;
  ncclComm_t global_comm = nullptr, local_comm = nullptr,
             external_comm = nullptr;
  paddle::platform::NCCLComm *nccl_comm_handle = nullptr,
                             *local_nccl_comm_handle = nullptr;
  distributed::NCCLCommContext *comm_ctx = nullptr, *local_comm_ctx = nullptr,
                               *external_comm_ctx = nullptr;

  const auto &comm_context_manager =
      phi::distributed::CommContextManager::GetInstance();

  if (FLAGS_dynamic_static_unified_comm) {
    CheckCommContextHasRingId(comm_context_manager, ring_ids[0]);

    comm_ctx = static_cast<phi::distributed::NCCLCommContext *>(
        comm_context_manager.Get(std::to_string(ring_ids[0])));
    PADDLE_ENFORCE_NE(comm_ctx,
                      nullptr,
                      paddle::platform::errors::Unavailable(
                          "NCCLCommContext is nullptr, collective op should "
                          "has ring_id attr."));

    global_comm = comm_ctx->GetNcclComm();
    global_rank = comm_ctx->GetRank();
    if (local_shard) {
      CheckCommContextHasRingId(comm_context_manager, ring_ids[1]);

      local_comm_ctx = static_cast<phi::distributed::NCCLCommContext *>(
          comm_context_manager.Get(std::to_string(ring_ids[1])));
      local_comm = local_comm_ctx->GetNcclComm();
      local_rank = local_comm_ctx->GetRank();
      if (use_hierarchical_allreduce) {
        CheckCommContextHasRingId(comm_context_manager, ring_ids[2]);

        external_comm_ctx = static_cast<phi::distributed::NCCLCommContext *>(
            comm_context_manager.Get(std::to_string(ring_ids[2])));
        external_comm = external_comm_ctx->GetNcclComm();
      }
    } else {
      local_comm = global_comm;
      local_rank = global_rank;
    }

    VLOG(3) << "new comm_context_manager has ring_id " << ring_ids[0];
  } else {
    if (nranks > 1) {
      nccl_comm_handle =
          paddle::platform::NCCLCommContext::Instance().Get(ring_ids[0], place);
      global_comm = nccl_comm_handle->comm();
      global_rank = nccl_comm_handle->rank();
      if (local_shard) {
        local_nccl_comm_handle =
            paddle::platform::NCCLCommContext::Instance().Get(ring_ids[1],
                                                              place);
        local_comm = local_nccl_comm_handle->comm();
        local_rank = local_nccl_comm_handle->rank();
        if (use_hierarchical_allreduce) {
          external_comm = paddle::platform::NCCLCommContext::Instance()
                              .Get(ring_ids[2], place)
                              ->comm();
        }
      } else {
        local_comm = global_comm;
        local_rank = global_rank;
      }
    }
  }

  memory_utils::Buffer grad_norm_square_buffer(place);
  auto *fp32_square_grad_norm = grad_norm_square_buffer.Alloc<float>(2);
  memory_utils::Buffer cub_tmp_buffer(place);
  memory_utils::Buffer sum_grad_buffer(place);
  float *fp32_sum_grad;
  dtype::float16 *fp16_sum_grad;
  auto fp32_numel_each_device = fp32_numel / num_devices;
  auto fp16_numel_each_device = fp16_numel / num_devices;
  if (local_shard) {
    auto ptr = sum_grad_buffer.Alloc<uint8_t>(
        fp32_numel * sizeof(float) + fp16_numel * sizeof(dtype::float16));
    fp32_sum_grad = has_fp32_param ? reinterpret_cast<float *>(ptr) : nullptr;
    fp16_sum_grad = has_fp16_param ? reinterpret_cast<dtype::float16 *>(
                                         ptr + fp32_numel * sizeof(float))
                                   : nullptr;
  } else if (nranks > 1 ||
             (max_global_grad_norm > 0 && !clip_after_allreduce)) {
    auto ptr = sum_grad_buffer.Alloc<uint8_t>(
        fp32_numel_each_device * sizeof(float) +
        fp16_numel_each_device * sizeof(dtype::float16));
    fp32_sum_grad = has_fp32_param ? reinterpret_cast<float *>(ptr) : nullptr;
    fp16_sum_grad = has_fp16_param
                        ? reinterpret_cast<dtype::float16 *>(
                              ptr + fp32_numel_each_device * sizeof(float))
                        : nullptr;
  } else {
    // NOTE: The const_cast here is not important. The fp32_sum_grad and
    // fp16_sum_grad would not be changed when num_devices == 1
    // But if I do not perform const_cast here, there would be more
    // if-else codes (num_devices > 1) when I write the following code.
    // So I prefer to use const_cast to unify the following code to reduce
    // the if-else codes.
    fp32_sum_grad = const_cast<float *>(fp32_grad_data);
    fp16_sum_grad = const_cast<dtype::float16 *>(fp16_grad_data);
  }
  float rescale_grad = 1.0f;
  if (!is_grad_scaled_by_nranks) {
    rescale_grad /= nranks;
  }

  if (max_global_grad_norm > 0) {
    if (clip_after_allreduce) {
      // (1) ReduceScater first
      if (local_shard) {
        if (use_hierarchical_allreduce) {
          NCCLReduceScatterWithScale(
              fp32_grad_data,
              fp32_sum_grad + local_rank * fp32_numel_each_device,
              fp32_numel_each_device,
              num_devices,
              local_comm,
              stream,
              dev_ctx,
              local_comm_ctx);
          NCCLAllReduceWithScale(
              fp32_sum_grad + local_rank * fp32_numel_each_device,
              fp32_sum_grad + local_rank * fp32_numel_each_device,
              fp32_numel_each_device,
              nranks / num_devices,
              external_comm,
              stream,
              dev_ctx,
              external_comm_ctx);

          NCCLReduceScatterWithScale(
              fp16_grad_data,
              fp16_sum_grad + local_rank * fp16_numel_each_device,
              fp16_numel_each_device,
              num_devices,
              local_comm,
              stream,
              dev_ctx,
              local_comm_ctx);
          NCCLAllReduceWithScale(
              fp16_sum_grad + local_rank * fp16_numel_each_device,
              fp16_sum_grad + local_rank * fp16_numel_each_device,
              fp16_numel_each_device,
              nranks / num_devices,
              external_comm,
              stream,
              dev_ctx,
              external_comm_ctx);
        } else {
          NCCLAllReduceWithScale(fp32_grad_data,
                                 fp32_sum_grad,
                                 fp32_numel,
                                 nranks,
                                 global_comm,
                                 stream,
                                 dev_ctx,
                                 comm_ctx);
          NCCLAllReduceWithScale(fp16_grad_data,
                                 fp16_sum_grad,
                                 fp16_numel,
                                 nranks,
                                 global_comm,
                                 stream,
                                 dev_ctx,
                                 comm_ctx);
        }
        fp32_sum_grad += (local_rank * fp32_numel_each_device);
        fp16_sum_grad += (local_rank * fp16_numel_each_device);
      } else {
        NCCLReduceScatterWithScale(fp32_grad_data,
                                   fp32_sum_grad,
                                   fp32_numel_each_device,
                                   nranks,
                                   global_comm,
                                   stream,
                                   dev_ctx,
                                   comm_ctx);
        NCCLReduceScatterWithScale(fp16_grad_data,
                                   fp16_sum_grad,
                                   fp16_numel_each_device,
                                   nranks,
                                   global_comm,
                                   stream,
                                   dev_ctx,
                                   comm_ctx);
      }
      // (2) Calculate the global grad norm
      GetSquareGradNorm(fp32_sum_grad,
                        fp32_numel_each_device,
                        fp16_sum_grad,
                        fp16_numel_each_device,
                        fp32_square_grad_norm,
                        stream,
                        &cub_tmp_buffer);
      VLOG(1) << "Grad square norm before all reduce: "
              << FlattenToString(fp32_square_grad_norm, 1, place);
      if (num_devices > 1) {
        // TODO(BeingGod): NCCLCommContext::AllReduce only accept DenseTensor,
        // but fp32_square_grad_norm is allocated by Buffer.
        PADDLE_ENFORCE_GPU_SUCCESS(
            phi::dynload::ncclAllReduce(fp32_square_grad_norm,
                                        fp32_square_grad_norm,
                                        1,
                                        ncclFloat32,
                                        ncclSum,
                                        local_comm,
                                        stream));
      }
      VLOG(1) << "Grad square norm after all reduce: "
              << FlattenToString(fp32_square_grad_norm, 1, place);
    } else {
      // (1) Calculate the local grad norm
      GetSquareGradNorm(fp32_grad_data,
                        fp32_numel,
                        fp16_grad_data,
                        fp16_numel,
                        fp32_square_grad_norm,
                        stream,
                        &cub_tmp_buffer);
      VLOG(1) << "Grad square norm before all reduce: "
              << FlattenToString(fp32_square_grad_norm, 1, place);
      // (2) Calculate the gradient clip scale
      float *fp32_scale = nullptr;
      dtype::float16 *fp16_scale = nullptr;
      if (has_fp32_param && has_fp16_param) {
        auto *ptr = cub_tmp_buffer.Alloc<uint8_t>(sizeof(float) +
                                                  sizeof(dtype::float16));
        fp32_scale = reinterpret_cast<float *>(ptr);
        fp16_scale = reinterpret_cast<dtype::float16 *>(ptr + sizeof(float));
      } else if (has_fp32_param) {
        fp32_scale = cub_tmp_buffer.Alloc<float>(1);
      } else {
        fp16_scale = cub_tmp_buffer.Alloc<dtype::float16>(1);
      }
      float clip_scale = 1.0f;
      if (is_grad_scaled_by_nranks) {
        clip_scale *= nranks;
      }
      CalcGradNormClipBeforeAllReduceScale<float, dtype::float16>
          <<<1, 1, 0, stream>>>(global_scale_data,
                                max_global_grad_norm,
                                fp32_square_grad_norm,
                                fp32_scale,
                                fp16_scale,
                                clip_scale);
      if (fp32_scale) {
        VLOG(1) << "Grad scale: " << FlattenToString(fp32_scale, 1, place);
      } else {
        VLOG(1) << "Grad scale: " << FlattenToString(fp16_scale, 1, place);
      }
      // (3) Do ReduceScatter with scale
      VLOG(1) << "FP32 HasNanInf before all reduce: "
              << HasNanInf(dev_ctx, fp32_grad_data, fp32_numel);
      VLOG(1) << "FP16 HasNanInf before all reduce: "
              << HasNanInf(dev_ctx, fp16_grad_data, fp16_numel);
      if (local_shard) {
        if (use_hierarchical_allreduce) {
          NCCLReduceScatterWithScale(
              fp32_grad_data,
              fp32_sum_grad + local_rank * fp32_numel_each_device,
              fp32_numel_each_device,
              num_devices,
              local_comm,
              stream,
              dev_ctx,
              local_comm_ctx,
              fp32_scale);
          NCCLAllReduceWithScale(
              fp32_sum_grad + local_rank * fp32_numel_each_device,
              fp32_sum_grad + local_rank * fp32_numel_each_device,
              fp32_numel_each_device,
              nranks / num_devices,
              external_comm,
              stream,
              dev_ctx,
              external_comm_ctx);
          NCCLReduceScatterWithScale(
              fp16_grad_data,
              fp16_sum_grad + local_rank * fp16_numel_each_device,
              fp16_numel_each_device,
              num_devices,
              local_comm,
              stream,
              dev_ctx,
              local_comm_ctx,
              fp16_scale);
          NCCLAllReduceWithScale(
              fp16_sum_grad + local_rank * fp16_numel_each_device,
              fp16_sum_grad + local_rank * fp16_numel_each_device,
              fp16_numel_each_device,
              nranks / num_devices,
              external_comm,
              stream,
              dev_ctx,
              external_comm_ctx);
        } else {
          NCCLAllReduceWithScale(fp32_grad_data,
                                 fp32_sum_grad,
                                 fp32_numel,
                                 nranks,
                                 global_comm,
                                 stream,
                                 dev_ctx,
                                 comm_ctx,
                                 fp32_scale);
          NCCLAllReduceWithScale(fp16_grad_data,
                                 fp16_sum_grad,
                                 fp16_numel,
                                 nranks,
                                 global_comm,
                                 stream,
                                 dev_ctx,
                                 comm_ctx,
                                 fp16_scale);
        }
        fp32_sum_grad += (local_rank * fp32_numel_each_device);
        fp16_sum_grad += (local_rank * fp16_numel_each_device);
      } else {
        NCCLReduceScatterWithScale(fp32_grad_data,
                                   fp32_sum_grad,
                                   fp32_numel_each_device,
                                   nranks,
                                   global_comm,
                                   stream,
                                   dev_ctx,
                                   comm_ctx,
                                   fp32_scale);
        NCCLReduceScatterWithScale(fp16_grad_data,
                                   fp16_sum_grad,
                                   fp16_numel_each_device,
                                   nranks,
                                   global_comm,
                                   stream,
                                   dev_ctx,
                                   comm_ctx,
                                   fp16_scale);
      }
      VLOG(1) << "FP32 HasNanInf after all reduce: "
              << HasNanInf(dev_ctx, fp32_sum_grad, fp32_numel_each_device);
      VLOG(1) << "FP16 HasNanInf after all reduce: "
              << HasNanInf(dev_ctx, fp16_sum_grad, fp16_numel_each_device);
      CheckHasNanInfGrad(fp32_sum_grad,
                         fp32_numel_each_device,
                         fp16_sum_grad,
                         fp16_numel_each_device,
                         fp32_square_grad_norm,
                         stream,
                         &cub_tmp_buffer);
      if (num_devices > 1) {
        // TODO(BeingGod): NCCLCommContext::AllReduce only accept DenseTensor,
        // but fp32_square_grad_norm is allocated by Buffer.
        PADDLE_ENFORCE_GPU_SUCCESS(
            phi::dynload::ncclAllReduce(fp32_square_grad_norm,
                                        fp32_square_grad_norm,
                                        1,
                                        ncclFloat32,
                                        ncclSum,
                                        local_comm,
                                        stream));
        VLOG(1) << "Grad square norm after all reduce: "
                << FlattenToString(fp32_square_grad_norm, 1, place);
      }
      // (4) mark max_global_grad_norm as 0, meaning that clip has been
      // already performed
      max_global_grad_norm = 0;
    }
  } else {
    if (local_shard) {
      if (use_hierarchical_allreduce) {
        NCCLReduceScatterWithScale(
            fp32_grad_data,
            fp32_sum_grad + local_rank * fp32_numel_each_device,
            fp32_numel_each_device,
            num_devices,
            local_comm,
            stream,
            dev_ctx,
            local_comm_ctx);
        NCCLAllReduceWithScale(
            fp32_sum_grad + local_rank * fp32_numel_each_device,
            fp32_sum_grad + local_rank * fp32_numel_each_device,
            fp32_numel_each_device,
            nranks / num_devices,
            external_comm,
            stream,
            dev_ctx,
            external_comm_ctx);
        NCCLReduceScatterWithScale(
            fp16_grad_data,
            fp16_sum_grad + local_rank * fp16_numel_each_device,
            fp16_numel_each_device,
            num_devices,
            local_comm,
            stream,
            dev_ctx,
            local_comm_ctx);
        NCCLAllReduceWithScale(
            fp16_sum_grad + local_rank * fp16_numel_each_device,
            fp16_sum_grad + local_rank * fp16_numel_each_device,
            fp16_numel_each_device,
            nranks / num_devices,
            external_comm,
            stream,
            dev_ctx,
            external_comm_ctx);
      } else {
        NCCLAllReduceWithScale(fp32_grad_data,
                               fp32_sum_grad,
                               fp32_numel,
                               nranks,
                               global_comm,
                               stream,
                               dev_ctx,
                               comm_ctx);
        NCCLAllReduceWithScale(fp16_grad_data,
                               fp16_sum_grad,
                               fp16_numel,
                               nranks,
                               global_comm,
                               stream,
                               dev_ctx,
                               comm_ctx);
      }
      fp32_sum_grad += (local_rank * fp32_numel_each_device);
      fp16_sum_grad += (local_rank * fp16_numel_each_device);
    } else {
      NCCLReduceScatterWithScale(fp32_grad_data,
                                 fp32_sum_grad,
                                 fp32_numel_each_device,
                                 num_devices,
                                 global_comm,
                                 stream,
                                 dev_ctx,
                                 comm_ctx);
      NCCLReduceScatterWithScale(fp16_grad_data,
                                 fp16_sum_grad,
                                 fp16_numel_each_device,
                                 num_devices,
                                 global_comm,
                                 stream,
                                 dev_ctx,
                                 comm_ctx);
    }
    CheckHasNanInfGrad(fp32_sum_grad,
                       fp32_numel_each_device,
                       fp16_sum_grad,
                       fp16_numel_each_device,
                       fp32_square_grad_norm,
                       stream,
                       &cub_tmp_buffer);
    if (num_devices > 1) {
      // TODO(BeingGod): NCCLCommContext::AllReduce only accept DenseTensor,
      // but fp32_square_grad_norm is allocated by Buffer.
      PADDLE_ENFORCE_GPU_SUCCESS(
          phi::dynload::ncclAllReduce(fp32_square_grad_norm,
                                      fp32_square_grad_norm,
                                      1,
                                      ncclFloat32,
                                      ncclSum,
                                      local_comm,
                                      stream));
    }
    max_global_grad_norm = 0;
  }
  VLOG(10) << "ReduceScatter done";

  // Step 7: update the moment1, moment2. Calcuate the trust_ratio_div
  auto *param_offsets_data = param_offsets.data<int>();
  const auto *fp32_partial_offsets_data = fp32_partial_offsets.data<int>();
  const auto *fp16_partial_offsets_data = fp16_partial_offsets.data<int>();
  auto *step_data = step->data<int64_t>();
  VLOG(1) << "FusedParamOffsets: "
          << FlattenToString(param_offsets_data,
                             param_offsets.numel(),
                             param_offsets.place());
  VLOG(1) << "FP32ShardFusedParamOffsets: "
          << FlattenToString(fp32_partial_offsets_data,
                             fp32_partial_offsets.numel(),
                             fp32_partial_offsets.place());
  VLOG(1) << "FP16ShardFusedParamOffsets: "
          << FlattenToString(fp16_partial_offsets_data,
                             fp16_partial_offsets.numel(),
                             fp16_partial_offsets.place());
  memory_utils::Buffer trust_ratio_div_buffer(place);
  auto *trust_ratio_div = trust_ratio_div_buffer.Alloc<float>(partial_numel);
  auto fp32_offset = local_rank * fp32_numel_each_device;
  auto fp16_offset = local_rank * fp16_numel_each_device;
  if (has_fp32_param) {
    VLOG(10) << "Update FP32 Moment and TrustRatioDiv starts";
    MultiTensorUpdateLambMomentAndTrustRatioDiv(dev_ctx,
                                                fp32_partial_offsets_data,
                                                fp32_local_param_num,
                                                fp32_param_data + fp32_offset,
                                                fp32_sum_grad,
                                                fp32_square_grad_norm,
                                                global_scale_data,
                                                beta1_pow_data,
                                                beta2_pow_data,
                                                moment1_data,
                                                moment2_data,
                                                trust_ratio_div,
                                                found_inf_data,
                                                step_data,
                                                weight_decay,
                                                fp32_weight_decay_end_idx,
                                                beta1,
                                                beta2,
                                                epsilon,
                                                max_global_grad_norm,
                                                rescale_grad);
    VLOG(10) << "Update FP32 Moment and TrustRatioDiv done";
  }
  float *master_param = nullptr;
  if (has_fp16_param) {
    master_param = fp32_param_data + fp32_numel;
    VLOG(10) << "Update FP16 Moment and TrustRatioDiv starts";
    auto tmp_found_inf = has_fp32_param ? nullptr : found_inf_data;
    auto tmp_step = has_fp32_param ? nullptr : step_data;
    MultiTensorUpdateLambMomentAndTrustRatioDiv(
        dev_ctx,
        fp16_partial_offsets_data,
        fp16_local_param_num,
        master_param + fp16_offset,
        fp16_sum_grad,
        fp32_square_grad_norm,
        global_scale_data,
        beta1_pow_data,
        beta2_pow_data,
        moment1_data + fp32_numel_each_device,
        moment2_data + fp32_numel_each_device,
        trust_ratio_div + fp32_numel_each_device,
        tmp_found_inf,
        tmp_step,
        weight_decay,
        fp16_weight_decay_end_idx,
        beta1,
        beta2,
        epsilon,
        max_global_grad_norm,
        rescale_grad);
    VLOG(10) << "Update FP16 Moment and TrustRatioDiv done";
  }

  VLOG(10) << "Update Moment and TrustRatioDiv done hehahaha";

  // Step 8: calculate L2-Norm square of parameter and trust_ratio_div
  memory_utils::Buffer square_norm_buffer(place);
  auto *param_square_norm = square_norm_buffer.Alloc<float>(2 * param_num);
  auto *trust_ratio_div_square_norm = param_square_norm + param_num;
  if (num_devices > 1) {
    if (use_master_param_norm) {
      FillZeroWithPtr(param_square_norm + fp32_global_param_num,
                      2 * param_num - fp32_global_param_num,
                      stream);
    } else {
      FillZeroWithPtr(trust_ratio_div_square_norm, param_num, stream);
    }
  }
  MultiTensorL2Norm(place,
                    stream,
                    fp32_param_data,
                    param_offsets_data,
                    fp32_global_param_num,
                    param_square_norm);
  if (use_master_param_norm) {
    MultiTensorL2Norm(place,
                      stream,
                      master_param + fp16_offset,
                      fp16_partial_offsets_data,
                      fp16_local_param_num,
                      param_square_norm + fp16_local_start_idx);
  } else {
    MultiTensorL2Norm(place,
                      stream,
                      fp16_param_data +
                          param_offsets_data[fp16_local_start_idx] -
                          param_offsets_data[fp32_global_param_num],
                      param_offsets_data + fp16_local_start_idx,
                      fp16_local_param_num,
                      param_square_norm + fp16_local_start_idx);
  }
  MultiTensorL2Norm(place,
                    stream,
                    trust_ratio_div,
                    fp32_partial_offsets_data,
                    fp32_local_param_num,
                    trust_ratio_div_square_norm + fp32_local_start_idx);
  MultiTensorL2Norm(place,
                    stream,
                    trust_ratio_div + fp32_numel_each_device,
                    fp16_partial_offsets_data,
                    fp16_local_param_num,
                    trust_ratio_div_square_norm + fp16_local_start_idx);
  VLOG(1) << "TrustRatioDiv L2-Norm before allreduce: "
          << FlattenToString(trust_ratio_div_square_norm, param_num, place);
  if (num_devices > 1) {
    if (use_master_param_norm) {
      // TODO(BeingGod): NCCLCommContext::AllReduce only accept DenseTensor,
      // but param_square_norm is allocated by Buffer.
      PADDLE_ENFORCE_GPU_SUCCESS(
          phi::dynload::ncclAllReduce(param_square_norm + fp32_global_param_num,
                                      param_square_norm + fp32_global_param_num,
                                      2 * param_num - fp32_global_param_num,
                                      ncclFloat32,
                                      ncclSum,
                                      local_comm,
                                      stream));
    } else {
      // TODO(BeingGod): NCCLCommContext::AllReduce only accept DenseTensor,
      // but trust_ratio_div_square_norm is allocated by Buffer.
      PADDLE_ENFORCE_GPU_SUCCESS(
          phi::dynload::ncclAllReduce(trust_ratio_div_square_norm,
                                      trust_ratio_div_square_norm,
                                      param_num,
                                      ncclFloat32,
                                      ncclSum,
                                      local_comm,
                                      stream));
    }
    VLOG(10) << "ncclAllReduce done";
  }

  LogParamAndTrustRatioDivSquareNorm<1>(
      param, param_order, param_square_norm, trust_ratio_div_square_norm);
  VLOG(10) << "Calculate L2-Norm of Param and TrustRatioDiv done";

  // Step 9: update parameter, beta1pow, beta2pow. All gather parameters.
  if (has_fp32_param) {
    MultiTensorUpdateLambParamAndBetaPows<float>(
        dev_ctx,
        fp32_partial_offsets_data,
        fp32_local_param_num,
        trust_ratio_div,
        lr_data,
        param_square_norm + fp32_local_start_idx,
        trust_ratio_div_square_norm + fp32_local_start_idx,
        found_inf_data,
        fp32_param_data + fp32_offset,
        nullptr,
        beta1_pow_data,
        beta2_pow_data,
        beta1,
        beta2);
    if (num_devices > 1) {
      // ncclAllGather
      if (local_comm_ctx) {
        auto send_buf = distributed::GetPartialTensor(
            *fp32_param_out, fp32_offset, fp32_numel_each_device);
        auto recv_buf = distributed::GetPartialTensor(
            *fp32_param_out, 0, fp32_numel_each_device);
        local_comm_ctx->AllGather(&recv_buf, send_buf, stream);
      } else {
        PADDLE_ENFORCE_GPU_SUCCESS(
            phi::dynload::ncclAllGather(fp32_param_data + fp32_offset,
                                        fp32_param_data,
                                        fp32_numel_each_device,
                                        ncclFloat32,
                                        local_comm,
                                        stream));
      }
    }

    beta1_pow_data = nullptr;
    beta2_pow_data = nullptr;
  }
  if (has_fp16_param) {
    MultiTensorUpdateLambParamAndBetaPows<dtype::float16>(
        dev_ctx,
        fp16_partial_offsets_data,
        fp16_local_param_num,
        trust_ratio_div + fp32_numel_each_device,
        lr_data,
        param_square_norm + fp16_local_start_idx,
        trust_ratio_div_square_norm + fp16_local_start_idx,
        found_inf_data,
        fp16_param_data + fp16_offset,
        master_param + fp16_offset,
        beta1_pow_data,
        beta2_pow_data,
        beta1,
        beta2);
    if (num_devices > 1) {
      // ncclAllGather
      if (local_comm_ctx) {
        auto send_buf = distributed::GetPartialTensor(
            *fp16_param_out, fp16_offset, fp16_numel_each_device);
        auto recv_buf = distributed::GetPartialTensor(
            *fp16_param_out, 0, fp16_numel_each_device);
        local_comm_ctx->AllGather(&recv_buf, send_buf, stream);
      } else {
        PADDLE_ENFORCE_GPU_SUCCESS(
            phi::dynload::ncclAllGather(fp16_param_data + fp16_offset,
                                        fp16_param_data,
                                        fp16_numel_each_device,
                                        ncclFloat16,
                                        local_comm,
                                        stream));
      }
    }
  }
  VLOG(10) << "Update Param done";

  VLOG(1) << "IsFinite: " << IsFinite(dev_ctx, fp32_square_grad_norm);
#else
  PADDLE_THROW(phi::errors::Unimplemented(
      "distributed_fused_lamb op should be used with NCCL/RCCL."));
#endif
}

}  // namespace fusion
}  // namespace phi

PD_REGISTER_KERNEL(distributed_fused_lamb,
                   GPU,
                   ALL_LAYOUT,
                   phi::fusion::DistributedFusedLambKernel,
                   float) {
  kernel->InputAt(10).SetBackend(phi::Backend::CPU);
  kernel->InputAt(11).SetBackend(phi::Backend::CPU);
  kernel->InputAt(12).SetBackend(phi::Backend::CPU);
  kernel->InputAt(13).SetBackend(phi::Backend::CPU);
  kernel->InputAt(14).SetBackend(phi::Backend::CPU);

  kernel->OutputAt(0).SetDataType(phi::DataType::FLOAT32);
  kernel->OutputAt(1).SetDataType(phi::DataType::FLOAT16);
  kernel->OutputAt(2).SetDataType(phi::DataType::FLOAT32);
  kernel->OutputAt(3).SetDataType(phi::DataType::FLOAT16);
  kernel->OutputAt(4).SetDataType(phi::DataType::FLOAT32);
  kernel->OutputAt(5).SetDataType(phi::DataType::FLOAT32);
  kernel->OutputAt(6).SetDataType(phi::DataType::FLOAT32);
  kernel->OutputAt(7).SetDataType(phi::DataType::FLOAT32);
  kernel->OutputAt(9).SetDataType(phi::DataType::BOOL);
  kernel->OutputAt(10).SetDataType(phi::DataType::INT64);
  kernel->OutputAt(11).SetDataType(phi::DataType::BOOL);
  kernel->OutputAt(12).SetDataType(phi::DataType::INT64);
}
