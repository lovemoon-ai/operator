cmake_minimum_required(VERSION 3.22)

# hand_capture — full-rate hand-joint capture GDExtension.
# Reads XRHandTracker joints once per XR frame, packs the HJNT v1 payload
# in C++ and mirrors the optional hands.jsonl sidecar on a background
# thread, replacing the 30 Hz GDScript hand path in pose_sampler.gd.

project(hand_capture
    LANGUAGES CXX
    DESCRIPTION "Native full-rate XRHandTracker capture for the Operator XR client"
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Android-only, matching the runtime it serves (the desktop editor falls
# back to the GDScript path when this class is absent).
if(NOT ANDROID)
    message(FATAL_ERROR "hand_capture is Android-only — pass -DCMAKE_TOOLCHAIN_FILE=\$ANDROID_NDK/build/cmake/android.toolchain.cmake")
endif()

# --- godot-cpp ----------------------------------------------------
# Shared checkout in repo-level .deps/src/godot-cpp, consumed through the
# godot-cpp symlink created by build.sh (same pattern as ahb_decoder).
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
add_library(hand_capture SHARED
    src/register_types.cpp
    src/background_jsonl_writer.cpp
    src/variant_json.cpp
    src/native_hand_sampler.cpp
    src/native_body_motion_writer.cpp
    src/native_openxr_hand_capture.cpp
)

target_include_directories(hand_capture PRIVATE
    src
    "${GODOT_CPP_DIR}/include"
    "${GODOT_CPP_DIR}/gen/include"
)

target_link_libraries(hand_capture PRIVATE
    godot-cpp
    dl
    log           # __android_log_print via godot-cpp warnings
)

target_link_options(hand_capture PRIVATE "LINKER:--exclude-libs,ALL")

set_target_properties(hand_capture PROPERTIES
    OUTPUT_NAME "hand_capture"
    PREFIX "lib"
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
)

install(TARGETS hand_capture
    LIBRARY DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/../../android/build/libs/${ANDROID_ABI}"
)
