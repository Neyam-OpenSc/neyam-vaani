# Neyam Vaani — llama_bridge (on-device LLM)
#
# Builds libnv_llama_bridge.so: a plain-C FFI bridge (no Java JNI) between
# Dart (dart:ffi) and llama.cpp, running quantized GGUF models (Qwen2.5
# 1.5B/3B-Instruct by default) fully offline on the CPU.
#
# llama.cpp is fetched at configure time. DEFAULT is a pinned tag: the
# bridge is written against llama.cpp master as of October 2026 (sampler
# chain API, llama_perf_context, llama_memory_seq_rm, LLAMA_LOAD_MODE_*).
# When you bump the pin, re-read native/llama_bridge/llama_bridge.cpp
# against the upstream llama.h — the API moves fast.

cmake_minimum_required(VERSION 3.22)
project(nv_llama_bridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

include(FetchContent)

set(NV_LLAMA_CPP_TAG "b7600" CACHE STRING "llama.cpp git tag/commit to fetch (pin deliberately)")

# Keep the upstream build minimal and network-free. LLAMA_CURL=OFF is a
# privacy requirement (PRIVACY_CHARTER.md): the runtime must not grow any
# network capability.
set(LLAMA_CURL          OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER  OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON  OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS   OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE         OFF CACHE BOOL "" FORCE) # cross-compiling for Android ABIs
set(GGML_OPENMP         OFF CACHE BOOL "" FORCE) # NDK r26+ has no OpenMP runtime

FetchContent_Declare(
    llamacpp
    GIT_REPOSITORY https://github.com/ggml-org/llama.cpp
    GIT_TAG        ${NV_LLAMA_CPP_TAG}
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(llamacpp)

add_library(nv_llama_bridge SHARED llama_bridge.cpp)

target_compile_options(nv_llama_bridge PRIVATE
    -O3
    -fvisibility=hidden          # only NV_EXPORT symbols escape the .so
    -Wall -Wextra
)
if(ANDROID)
    target_link_options(nv_llama_bridge PRIVATE "-Wl,-z,max-page-size=16384")
endif()

target_link_libraries(nv_llama_bridge
    PRIVATE
        llama            # llama.cpp + ggml (static, via FetchContent)
        log
)
target_include_directories(nv_llama_bridge PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
