file(GLOB_RECURSE transforms_srcs "*.cc")
if(NOT WITH_CINN)
  list(
    REMOVE_ITEM transforms_srcs ${CMAKE_CURRENT_SOURCE_DIR}/build_cinn_pass.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/sub_graph_extract_pass.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/sub_graph_detector.cc)
endif()

if(NOT WITH_MKLDNN)
  file(GLOB_RECURSE onednn_srcs "onednn/*.cc")
  list(REMOVE_ITEM transforms_srcs ${onednn_srcs})
endif()

set(transforms_deps drr op_dialect op_dialect_vjp standalone_executor pir
                    device_event_base)

if(WITH_CINN)
  set(transforms_deps ${transforms_deps} cinn_op_dialect cinnapi)
endif()

cc_library(
  pir_transforms
  SRCS ${transforms_srcs}
  DEPS ${transforms_deps})
