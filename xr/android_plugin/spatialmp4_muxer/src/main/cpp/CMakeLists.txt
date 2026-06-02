cmake_minimum_required(VERSION 3.22.1)

project(spatialmp4_writer LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(FFMPEG_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/ffmpeg/${ANDROID_ABI}" CACHE PATH
    "Patched FFmpeg install root for Android")

if(NOT EXISTS "${FFMPEG_ROOT}/include/libavformat/avformat.h")
    message(FATAL_ERROR
        "Patched FFmpeg for ${ANDROID_ABI} was not found at ${FFMPEG_ROOT}. "
        "Run android_plugin/scripts/build_android_ffmpeg.sh first.")
endif()

function(import_ffmpeg_lib target_name lib_name)
    add_library(${target_name} STATIC IMPORTED)
    set_target_properties(${target_name} PROPERTIES
        IMPORTED_LOCATION "${FFMPEG_ROOT}/lib/${lib_name}"
    )
endfunction()

import_ffmpeg_lib(ffmpeg_avformat libavformat.a)
import_ffmpeg_lib(ffmpeg_avcodec libavcodec.a)
import_ffmpeg_lib(ffmpeg_avutil libavutil.a)

add_library(spatialmp4_writer SHARED
    spatialmp4_writer_jni.cpp
)

target_include_directories(spatialmp4_writer PRIVATE
    "${FFMPEG_ROOT}/include"
)

target_compile_options(spatialmp4_writer PRIVATE
    -Wall
    -Wextra
    -Werror
)

target_link_libraries(spatialmp4_writer PRIVATE
    ffmpeg_avformat
    ffmpeg_avcodec
    ffmpeg_avutil
    log
    z
    m
)
