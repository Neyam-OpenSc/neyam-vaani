# Neyam Vaani — nllb_bridge (on-device translation)
#
# Builds libnv_nllb_bridge.so: a plain-C FFI bridge (no Java JNI) between
# Dart (dart:ffi) and a compact ggml-based runtime for the M2M100/NLLB
# architecture (NLLB-200-distilled-600M in q4_0/q8_0), with SentencePiece
# tokenization. Fully offline — the runtime has no network code at all.
#
# Runtime note: unlike the other bridges, there is no canonical upstream
# NLLB inference engine for ggml. This bridge therefore contains its own
# minimal M2M100 encoder/decoder forward pass (see nllb_bridge.cpp) written
# directly against the ggml C API, plus a documented weight-file format
# (.nvbin) produced by the planned models/quantize_models.py converter.
# Only generic building blocks are fetched:
#   * ggml        (compute backend)
#   * sentencepiece (tokenizer)

cmake_minimum_required(VERSION 3.22)
project(nv_nllb_bridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

include(FetchContent)

# ---- ggml -------------------------------------------------------------------
# Pin deliberately: the bridge uses the stable legacy CPU graph API
# (ggml_build_forward / ggml_graph_compute_with_ctx / ggml_blck_size).
set(NV_GGML_TAG "master" CACHE STRING "ggml git tag/commit to fetch (pin a commit in CI!)")

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE     OFF CACHE BOOL "" FORCE) # cross-compiling for Android ABIs
set(GGML_OPENMP     OFF CACHE BOOL "" FORCE) # NDK r26+ has no OpenMP runtime
set(GGML_BUILD_TESTS   OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    ggml
    GIT_REPOSITORY https://github.com/ggml-org/ggml
    GIT_TAG        ${NV_GGML_TAG}
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(ggml)

# ---- sentencepiece ----------------------------------------------------------

set(NV_SENTENCEPIECE_TAG "v0.2.0" CACHE STRING "sentencepiece git tag to fetch")
set(SPM_BUILD_TESTING OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    sentencepiece
    GIT_REPOSITORY https://github.com/google/sentencepiece
    GIT_TAG        ${NV_SENTENCEPIECE_TAG}
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(sentencepiece)

# ---- bridge -----------------------------------------------------------------

add_library(nv_nllb_bridge SHARED nllb_bridge.cpp)

target_compile_options(nv_nllb_bridge PRIVATE
    -O3
    -fvisibility=hidden          # only NV_EXPORT symbols escape the .so
    -Wall -Wextra
)
if(ANDROID)
    target_link_options(nv_nllb_bridge PRIVATE "-Wl,-z,max-page-size=16384")
endif()

target_link_libraries(nv_nllb_bridge
    PRIVATE
        ggml                       # compute backend (CPU)
        sentencepiece              # tokenizer
        log
)
target_include_directories(nv_nllb_bridge PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
