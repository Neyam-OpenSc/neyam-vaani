# Neyam Vaani — whisper_bridge (STT)
#
# Builds libnv_whisper_bridge.so: a plain-C FFI bridge (no Java JNI) between
# Dart (dart:ffi) and whisper.cpp. Consumed only through app/lib/data/services/.
#
# Android (arm64-v8a + armeabi-v7a):
#   Invoked from app/android/app/build.gradle via externalNativeBuild; the NDK
#   toolchain file sets ANDROID_ABI per flavor. Nothing to configure here.
#
# Host (dev machines, optional smoke builds):
#   cmake -B build -DNV_WHISPER_CPP_TAG=v1.7.5 && cmake --build build
#
# The whisper.cpp sources are fetched at configure time (never bundled in the
# repo, never shipped in the APK — models arrive via signed language packs).

cmake_minimum_required(VERSION 3.22)
project(nv_whisper_bridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

include(FetchContent)

# Pin whisper.cpp deliberately. v1.7.5 is the release this bridge was written
# against (whisper_context_params / whisper_full_params field set, abort_callback).
set(NV_WHISPER_CPP_TAG "v1.7.5" CACHE STRING "whisper.cpp git tag/commit to fetch")

# Keep the upstream build quiet and small: we only want the whisper library,
# no CLI tools, no tests, no OpenMP (removed from recent NDKs).
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE            OFF CACHE BOOL "" FORCE) # cross-compiling for Android ABIs
set(GGML_OPENMP            OFF CACHE BOOL "" FORCE) # NDK r26+ has no OpenMP runtime
if(ANDROID)
    set(GGML_CPU_ALL_VARIANTS OFF CACHE BOOL "" FORCE)
endif()

FetchContent_Declare(
    whispercpp
    GIT_REPOSITORY https://github.com/ggml-org/whisper.cpp
    GIT_TAG        ${NV_WHISPER_CPP_TAG}
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(whispercpp)

add_library(nv_whisper_bridge SHARED whisper_bridge.cpp)

target_compile_options(nv_whisper_bridge PRIVATE
    -O3
    -fvisibility=hidden          # only NV_EXPORT symbols escape the .so
    -Wall -Wextra
)
# 16 KB page sizes (Android 15+): keep ELF max-page-size aligned.
if(ANDROID)
    target_link_options(nv_whisper_bridge PRIVATE "-Wl,-z,max-page-size=16384")
endif()

target_link_libraries(nv_whisper_bridge
    PRIVATE
        whisper          # whisper.cpp (static, pulled via FetchContent)
        log              # __android_log_print
)
target_include_directories(nv_whisper_bridge PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
