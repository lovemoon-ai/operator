cmake_minimum_required(VERSION 3.22)

project(godot_mujoco
    LANGUAGES CXX
    DESCRIPTION "Godot GDExtension bridge for MuJoCo simulation on Android XR"
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT ANDROID)
    message(FATAL_ERROR "godot_mujoco is Android-only — pass -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake")
endif()

get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(GODOT_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp" CACHE PATH
    "Path to the godot-cpp source tree, normally the local symlink to .deps/src/godot-cpp")
set(GODOT_CPP_BUILD_DIR "${REPO_ROOT}/.deps/build/godot-cpp" CACHE PATH
    "Shared CMake build directory for godot-cpp")
set(MUJOCO_ROOT "$ENV{MUJOCO_ANDROID_ROOT}" CACHE PATH
    "Android MuJoCo install root with include/mujoco and lib/libmujoco.so")
if(NOT MUJOCO_ROOT)
    set(MUJOCO_ROOT "/home/duino/opt/mujoco_android")
endif()

if(NOT EXISTS "${GODOT_CPP_DIR}/SConstruct")
    message(FATAL_ERROR "godot-cpp not found at ${GODOT_CPP_DIR}. Run: make -C xr deps")
endif()
if(NOT EXISTS "${MUJOCO_ROOT}/include/mujoco/mujoco.h")
    message(FATAL_ERROR "MuJoCo headers not found at ${MUJOCO_ROOT}/include/mujoco/mujoco.h. Set MUJOCO_ANDROID_ROOT.")
endif()
if(NOT EXISTS "${MUJOCO_ROOT}/lib/libmujoco.so")
    message(FATAL_ERROR "MuJoCo Android library not found at ${MUJOCO_ROOT}/lib/libmujoco.so. Set MUJOCO_ANDROID_ROOT.")
endif()

add_subdirectory("${GODOT_CPP_DIR}" "${GODOT_CPP_BUILD_DIR}" EXCLUDE_FROM_ALL)
set_target_properties(godot-cpp PROPERTIES
    ARCHIVE_OUTPUT_DIRECTORY "${GODOT_CPP_BUILD_DIR}/bin"
)

add_library(godot_mujoco SHARED
    src/mujoco_native.cpp
    src/register_types.cpp
)

target_include_directories(godot_mujoco PRIVATE
    src
    "${GODOT_CPP_DIR}/include"
    "${GODOT_CPP_DIR}/gen/include"
    "${MUJOCO_ROOT}/include"
)

add_library(mujoco SHARED IMPORTED)
set_target_properties(mujoco PROPERTIES IMPORTED_LOCATION "${MUJOCO_ROOT}/lib/libmujoco.so")

target_link_libraries(godot_mujoco PRIVATE
    godot-cpp
    mujoco
    log
)

target_link_options(godot_mujoco PRIVATE "LINKER:--exclude-libs,ALL")

set_target_properties(godot_mujoco PROPERTIES
    OUTPUT_NAME "godot_mujoco"
    PREFIX "lib"
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
)

install(TARGETS godot_mujoco
    LIBRARY DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/../../android/build/libs/${ANDROID_ABI}"
)
