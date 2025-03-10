cc_library(
  benchmark
  SRCS benchmark.cc
  DEPS enforce common)

cc_library(
  infer_io_utils
  SRCS io_utils.cc
  DEPS paddle_inference_api lod_tensor shape_range_info_proto)
cc_library(
  model_utils
  SRCS model_utils.cc
  DEPS proto_desc enforce common)

cc_library(table_printer SRCS table_printer.cc)

proto_library(shape_range_info_proto SRCS shape_range_info.proto)

if(WITH_ONNXRUNTIME AND WIN32)
  # Copy onnxruntime for some c++ test in Windows, since the test will
  # be build only in CI, so suppose the generator in Windows is Ninja.
  copy_onnx(test_benchmark)
  copy_onnx(test_table_printer)
endif()
