cmake_minimum_required(VERSION 3.22)

project(pico_openxr
    LANGUAGES CXX
    DESCRIPTION "PICO OpenXR GDExtension bridge for external camera, body tracking, and motion trackers"
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT ANDROID)
    message(FATAL_ERROR "pico_openxr is Android-only — pass -DCMAKE_TOOLCHAIN_FILE=\$ANDROID_NDK/build/cmake/android.toolchain.cmake")
endif()

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

add_library(pico_openxr SHARED
    src/register_types.cpp
    src/pico_openxr_extension.cpp
)

target_include_directories(pico_openxr PRIVATE
    src
    "${GODOT_CPP_DIR}/include"
    "${GODOT_CPP_DIR}/gen/include"
)

target_link_libraries(pico_openxr PRIVATE
    godot-cpp
    log
)

set_target_properties(pico_openxr PROPERTIES
    OUTPUT_NAME "pico_openxr"
    PREFIX "lib"
)

install(TARGETS pico_openxr
    LIBRARY DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/../../android/build/libs/${ANDROID_ABI}"
)
