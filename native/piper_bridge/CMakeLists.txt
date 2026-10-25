# Neyam Vaani — piper_bridge (TTS)
#
# Builds libnv_piper_bridge.so: a plain-C FFI bridge (no Java JNI) between
# Dart (dart:ffi) and Piper (neural TTS, MIT). Piper in turn runs a VITS
# model on ONNX Runtime.
#
# Android (arm64-v8a + armeabi-v7a):
#   Piper's own CMake downloads prebuilt ONNX Runtime for desktop hosts, but
#   there is no Android tarball — you must provide ONNX Runtime for Android
#   yourself (extract the AAR/jar from Maven:
#     com.microsoft.onnxruntime:onnxruntime-android
#   ) and point ONNXRUNTIME_ROOT at it. The jniLibs inside also need to be
#   packaged into the APK (see README.md "Integration").
#
# Host (dev machines): ONNXRUNTIME_ROOT may stay empty; piper will fetch.

cmake_minimum_required(VERSION 3.22)
project(nv_piper_bridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

include(FetchContent)

# Pin Piper deliberately. 2023.11.14-2 is the 1.2.0 C++ API this bridge is
# written against (piper::initialize / loadVoice / textToAudio with a
# zero-argument audio callback that hands over audioBuffer).
set(NV_PIPER_TAG "2023.11.14-2" CACHE STRING "piper git tag/commit to fetch")

# ---- ONNX Runtime (Android only) -------------------------------------------

set(ONNXRUNTIME_ROOT "" CACHE PATH
    "Path to extracted onnxruntime-android (contains jni/{arm64-v8a,armeabi-v7a}/libonnxruntime.so)")

if(ANDROID AND NOT ONNXRUNTIME_ROOT)
    message(FATAL_ERROR
        "Piper needs ONNX Runtime for Android. Download the AAR from Maven "
        "(com.microsoft.onnxruntime:onnxruntime-android), unzip it, and pass "
        "-DONNXRUNTIME_ROOT=<aar-extract-dir> to CMake. See native/piper_bridge/README.md.")
endif()

if(ANDROID AND ONNXRUNTIME_ROOT)
    # Piper's cmake/onnxruntime.cmake honors these cache variables; without
    # them it would try to download a desktop build and fail under the NDK.
    set(ONNXRUNTIME_INCLUDE_DIR ${ONNXRUNTIME_ROOT}/headers CACHE PATH "" FORCE)
    set(ONNXRUNTIME_LIBDIR      ${ONNXRUNTIME_ROOT}/jni/${ANDROID_ABI} CACHE PATH "" FORCE)
endif()

# ---- Piper ------------------------------------------------------------------

set(BUILD_TESTING           OFF CACHE BOOL "" FORCE)
set(PIPER_BUILD_TESTS       OFF CACHE BOOL "" FORCE)
set(PIPER_BUILD_EXAMPLES    OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    piper
    GIT_REPOSITORY https://github.com/rhasspy/piper
    GIT_TAG        ${NV_PIPER_TAG}
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(piper)

add_library(nv_piper_bridge SHARED piper_bridge.cpp)

target_compile_options(nv_piper_bridge PRIVATE
    -O3
    -fvisibility=hidden          # only NV_EXPORT symbols escape the .so
    -Wall -Wextra
)
if(ANDROID)
    target_link_options(nv_piper_bridge PRIVATE "-Wl,-z,max-page-size=16384")
endif()

target_link_libraries(nv_piper_bridge
    PRIVATE
        piper            # piper + piper_phonemize (incl. espeak-ng)
        log
)
target_include_directories(nv_piper_bridge PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
