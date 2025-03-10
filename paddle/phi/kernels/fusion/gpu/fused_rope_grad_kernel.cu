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

#include "paddle/phi/backends/gpu/gpu_context.h"
#include "paddle/phi/backends/gpu/gpu_launch_config.h"
#include "paddle/phi/common/amp_type_traits.h"
#include "paddle/phi/core/enforce.h"
#include "paddle/phi/core/kernel_registry.h"
#include "paddle/phi/kernels/funcs/aligned_vector.h"
#include "paddle/phi/kernels/fusion/gpu/fused_rope_utils.h"

namespace phi {
namespace fusion {

template <typename T, typename Context>
void FusedRopeGradKernel(const Context& dev_ctx,
                         const paddle::optional<DenseTensor>& sin,
                         const paddle::optional<DenseTensor>& cos,
                         const paddle::optional<DenseTensor>& position_ids,
                         const DenseTensor& dout_q,
                         const paddle::optional<DenseTensor>& dout_k,
                         const paddle::optional<DenseTensor>& dout_v,
                         bool use_neox_rotary_style,
                         DenseTensor* dq,
                         DenseTensor* dk,
                         DenseTensor* dv) {
  int64_t numel = dout_q.numel();
  if (numel <= 0) return;
  dev_ctx.template Alloc<T>(dq);

  phi::Array<int64_t, 3> inputs_num_heads;
  // small size for broadcast
  auto batch_size = dout_q.dims()[0];
  inputs_num_heads[0] = dout_q.dims()[2];
  auto head_dim = dout_q.dims()[3];
  auto seq_len = dout_q.dims()[1];
  PADDLE_ENFORCE_NE(head_dim % 2,
                    1,
                    phi::errors::InvalidArgument(
                        "The head_dim of input must be a multiple of 2."));

  constexpr const int vec_size = 2;

  auto config =
      phi::backends::gpu::GetGpuLaunchConfig1D(dev_ctx, numel, vec_size);

  int64_t grid = config.block_per_grid.x;
  int64_t block = config.thread_per_block.x;
  auto stream = dev_ctx.stream();

  phi::Array<T*, 3> outs_data;
  phi::Array<const T*, 3> ins_data;
  phi::Array<const T*, 2> sin_cos_data;
  const int64_t* position_ids_data = NULL;

  ins_data[0] = dout_q.data<T>();
  outs_data[0] = dq->data<T>();
  int num_inputs = 1;

  if (dout_k) {
    dev_ctx.template Alloc<T>(dk);
    outs_data[num_inputs] = dk->data<T>();
    ins_data[num_inputs] = dout_k->data<T>();
    inputs_num_heads[num_inputs] = dk->dims()[2];
    num_inputs++;
  }

  if (dout_v) {
    dev_ctx.template Alloc<T>(dv);
    outs_data[num_inputs] = dv->data<T>();
    ins_data[num_inputs] = dout_v->data<T>();
    inputs_num_heads[num_inputs] = dv->dims()[2];
    num_inputs++;
  }

  using MPType = typename phi::dtype::MPTypeTrait<T>::Type;
  MPType div_c = static_cast<MPType>(1.0f / head_dim);

  bool flag_sin_cos = false;
  if (sin.get_ptr() && cos.get_ptr()) {
    sin_cos_data[0] = sin->data<T>();
    sin_cos_data[1] = cos->data<T>();

    flag_sin_cos = true;

    if (position_ids) {
      position_ids_data = position_ids->data<int64_t>();
    }
  }

  bool is_same_num_heads = true;
  auto prev_num_heads = inputs_num_heads[0];
  for (int i = 1; i < num_inputs; ++i) {
    if (prev_num_heads != inputs_num_heads[i]) {
      is_same_num_heads = false;
      break;
    }
    prev_num_heads = inputs_num_heads[i];
  }

  int sign = -1;
  if (is_same_num_heads) {
    VectorizedFusedRopeCudaKernelFunc<T, MPType, 3, vec_size> kernel_func_qkv =
        use_neox_rotary_style
            ? VectorizedFusedRopeWithRotateEveryTwoKernel<T,
                                                          MPType,
                                                          3,
                                                          vec_size>
            : VectorizedFusedRopeWithRotateHalfKernel<T, MPType, 3, vec_size>;
    kernel_func_qkv<<<grid, block, 0, stream>>>(ins_data,
                                                sin_cos_data,
                                                position_ids_data,
                                                flag_sin_cos,
                                                sign,
                                                batch_size,
                                                seq_len,
                                                inputs_num_heads[0],
                                                head_dim,
                                                outs_data,
                                                num_inputs,
                                                div_c);
  } else {
    VectorizedFusedRopeCudaKernelFunc<T, MPType, 1, vec_size> kernel_func_q =
        use_neox_rotary_style
            ? VectorizedFusedRopeWithRotateEveryTwoKernel<T,
                                                          MPType,
                                                          1,
                                                          vec_size>
            : VectorizedFusedRopeWithRotateHalfKernel<T, MPType, 1, vec_size>;
    VectorizedFusedRopeCudaKernelFunc<T, MPType, 2, vec_size> kernel_func_kv =
        use_neox_rotary_style
            ? VectorizedFusedRopeWithRotateEveryTwoKernel<T,
                                                          MPType,
                                                          2,
                                                          vec_size>
            : VectorizedFusedRopeWithRotateHalfKernel<T, MPType, 2, vec_size>;

    // rotary position embedding Q
    phi::Array<const T*, 1> input_q{ins_data[0]};
    phi::Array<T*, 1> out_q{outs_data[0]};
    kernel_func_q<<<grid, block, 0, stream>>>(input_q,
                                              sin_cos_data,
                                              position_ids_data,
                                              flag_sin_cos,
                                              sign,
                                              batch_size,
                                              seq_len,
                                              inputs_num_heads[0],
                                              head_dim,
                                              out_q,
                                              1,
                                              div_c);

    // rotary position embedding K,V
    phi::Array<const T*, 2> input_kv{ins_data[1], ins_data[2]};
    phi::Array<T*, 2> out_kv{outs_data[1], outs_data[2]};
    kernel_func_kv<<<grid, block, 0, stream>>>(input_kv,
                                               sin_cos_data,
                                               position_ids_data,
                                               flag_sin_cos,
                                               sign,
                                               batch_size,
                                               seq_len,
                                               inputs_num_heads[1],
                                               head_dim,
                                               out_kv,
                                               num_inputs - 1,
                                               div_c);
  }
}

}  // namespace fusion
}  // namespace phi

PD_REGISTER_KERNEL(fused_rotary_position_embedding_grad,
                   GPU,
                   ALL_LAYOUT,
                   phi::fusion::FusedRopeGradKernel,
                   float,
                   double,
                   phi::dtype::float16,
                   phi::dtype::bfloat16){};
