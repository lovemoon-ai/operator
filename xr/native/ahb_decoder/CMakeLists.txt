cmake_minimum_required(VERSION 3.22)

# ahb_decoder — Vulkan AHardwareBuffer GDExtension for the
# Teleoperate-Anything XR client. See README.md.

project(ahb_decoder
    LANGUAGES CXX
    DESCRIPTION "Zero-copy AHardwareBuffer -> Vulkan VkImage -> Godot Texture2DRD bridge"
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --- Sanity guard: this module is Android-only -------------------
# We rely on AHardwareBuffer (NDK API 26+) and Vulkan's
# VK_ANDROID_external_memory_android_hardware_buffer extension.
if(NOT ANDROID)
    message(FATAL_ERROR "ahb_decoder is Android-only — pass -DCMAKE_TOOLCHAIN_FILE=\$ANDROID_NDK/build/cmake/android.toolchain.cmake")
endif()

if(ANDROID_PLATFORM_LEVEL LESS 29)
    message(FATAL_ERROR "ahb_decoder needs API 29+ for VkAndroidHardwareBufferProperties; got level ${ANDROID_PLATFORM_LEVEL}")
endif()

# --- godot-cpp ----------------------------------------------------
# The real checkout lives in repo-level .deps/src/godot-cpp so multiple
# native plugins can share it. This plugin consumes it through the
# CMAKE_CURRENT_SOURCE_DIR/godot-cpp symlink created by build.sh.
get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(GODOT_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp" CACHE PATH
    "Path to the godot-cpp source tree, normally the local symlink to .deps/src/godot-cpp")
set(GODOT_CPP_BUILD_DIR "${REPO_ROOT}/.deps/build/godot-cpp" CACHE PATH
    "Shared CMake build directory for godot-cpp")
if(NOT EXISTS "${GODOT_CPP_DIR}/SConstruct")
    message(FATAL_ERROR
        "godot-cpp not found at ${GODOT_CPP_DIR}. The library will not build.\n"
        "Run:  make -C xr deps\n"
    )
endif()
add_subdirectory("${GODOT_CPP_DIR}" "${GODOT_CPP_BUILD_DIR}" EXCLUDE_FROM_ALL)
set_target_properties(godot-cpp PROPERTIES
    ARCHIVE_OUTPUT_DIRECTORY "${GODOT_CPP_BUILD_DIR}/bin"
)

# --- Library ------------------------------------------------------
add_library(ahb_decoder SHARED
    src/register_types.cpp
    src/ahb_video_texture.cpp
    src/jni_bridge.cpp
)

target_include_directories(ahb_decoder PRIVATE
    src
    "${GODOT_CPP_DIR}/include"
    "${GODOT_CPP_DIR}/gen/include"
)

target_link_libraries(ahb_decoder PRIVATE
    godot-cpp
    android       # for AHardwareBuffer_*
    log           # __android_log_print
    vulkan        # vk* symbols
    nativewindow  # AHardwareBuffer_describe etc. on API 26+
)

# Make sure the SONAME is what the GDExtension manifest expects.
set_target_properties(ahb_decoder PROPERTIES
    OUTPUT_NAME "ahb_decoder"
    PREFIX "lib"
)

# Where to drop the .so so the Godot Android gradle build can pick it up.
install(TARGETS ahb_decoder
    LIBRARY DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/../../android/build/libs/${ANDROID_ABI}"
)
