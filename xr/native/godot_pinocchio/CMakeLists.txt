cmake_minimum_required(VERSION 3.22)

# pinocchio_gd — thin Godot GDExtension wrapper around stack-of-tasks/pinocchio.
#
# The actual Pinocchio + Eigen3 + Boost build is produced by the pinocchio-android
# wrapper repo (synced into .deps/src/pinocchio-android and built via
# xr/makefiles/Makefile.pinocchio). This CMakeLists only builds the wrapper .so
# that Godot loads at runtime; it picks up Pinocchio through its installed
# CMake config + the vcpkg toolchain that produced it.

project(pinocchio_gd
    LANGUAGES CXX
    DESCRIPTION "Pinocchio rigid-body dynamics GDExtension (Android arm64-v8a)"
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --- Sanity guard: this module is Android-only -----------------------------
# Pinocchio itself can compile on desktop, but the wrapper is shipped only in
# the Android APK and we have not exercised any other toolchain here.
if(NOT ANDROID)
    message(FATAL_ERROR "pinocchio_gd is Android-only — pass -DCMAKE_TOOLCHAIN_FILE=\$ANDROID_NDK/build/cmake/android.toolchain.cmake")
endif()

# --- godot-cpp -------------------------------------------------------------
# Same vendoring pattern as native/ahb_decoder + native/pico_openxr: the real
# checkout lives in repo-level .deps/src/godot-cpp; this plugin consumes it
# through the CMAKE_CURRENT_SOURCE_DIR/godot-cpp symlink created by build.sh.
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

# --- Pinocchio install -----------------------------------------------------
# PINOCCHIO_INSTALL_DIR points at the install prefix produced by
# `make -C xr build-pinocchio`, i.e.
#   .deps/build/pinocchio-android/<abi>/src/build/android/<abi>/install
# build.sh resolves it and passes it in. The CMake config there
# (lib/cmake/pinocchio/pinocchioConfig.cmake) re-finds Eigen3 + Boost via
# `find_dependency`, which needs the vcpkg toolchain on
# CMAKE_PREFIX_PATH — build.sh handles that via VCPKG_ROOT.
set(PINOCCHIO_INSTALL_DIR "" CACHE PATH
    "Install prefix produced by `make build-pinocchio` (see xr/makefiles/Makefile.pinocchio)")
if(NOT PINOCCHIO_INSTALL_DIR OR NOT EXISTS "${PINOCCHIO_INSTALL_DIR}/lib/libpinocchio_default.so")
    message(FATAL_ERROR
        "Pinocchio install not found at PINOCCHIO_INSTALL_DIR=${PINOCCHIO_INSTALL_DIR}.\n"
        "Run:  make -C xr build-pinocchio   (requires ANDROID_NDK + VCPKG_ROOT)\n"
    )
endif()
list(PREPEND CMAKE_PREFIX_PATH "${PINOCCHIO_INSTALL_DIR}")

# pinocchio's exported config pulls Eigen3 + Boost in via find_dependency, so
# we don't list them again here. CONFIG mode is mandatory: pinocchio does not
# ship a FindModule.
find_package(pinocchio REQUIRED CONFIG)

# --- Library ---------------------------------------------------------------
add_library(pinocchio_gd SHARED
    src/register_types.cpp
    src/pinocchio_runtime.cpp
    src/pinocchio_model.cpp
    src/pinocchio_data.cpp
    src/pinocchio_multitask_solver.cpp
)

target_include_directories(pinocchio_gd PRIVATE
    src
    "${GODOT_CPP_DIR}/include"
    "${GODOT_CPP_DIR}/gen/include"
)

target_link_libraries(pinocchio_gd PRIVATE
    godot-cpp
    pinocchio::pinocchio   # libpinocchio_default.so + Eigen/Boost include dirs
    log                    # __android_log_print
)

target_link_options(pinocchio_gd PRIVATE "LINKER:--exclude-libs,ALL")

# Pinocchio's headers compile cleanly only at -O2+ on some Boost versions; we
# leave optimization to CMAKE_BUILD_TYPE but turn off Pinocchio's most spammy
# deprecation warnings so the CI log stays readable.
target_compile_definitions(pinocchio_gd PRIVATE
    PINOCCHIO_WITH_HPP_FCL=0           # no collision
    PINOCCHIO_WITH_URDFDOM=0           # no URDF
    EIGEN_MPL2_ONLY                    # match upstream wrapper config
)

set_target_properties(pinocchio_gd PROPERTIES
    OUTPUT_NAME "pinocchio_gd"
    PREFIX "lib"
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
)

# Drop the .so where the Godot Android gradle build can pick it up. build.sh
# additionally copies the wrapper + libpinocchio_default.so into
# addons/pinocchio/ so the GDExtension manifest can load them at runtime.
install(TARGETS pinocchio_gd
    LIBRARY DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/../../android/build/libs/${ANDROID_ABI}"
)
