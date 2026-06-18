cmake_minimum_required(VERSION 3.22)

project(godot_retargeting
    LANGUAGES CXX
    DESCRIPTION "Godot GDExtension bridge for the retargeting toolkit on Android XR"
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT ANDROID)
    message(FATAL_ERROR "godot_retargeting is Android-only — pass -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake")
endif()

get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(GODOT_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp" CACHE PATH
    "Path to the godot-cpp source tree (symlink to .deps/src/godot-cpp)")
set(GODOT_CPP_BUILD_DIR "${REPO_ROOT}/.deps/build/godot-cpp" CACHE PATH
    "Shared CMake build directory for godot-cpp")
set(MUJOCO_ROOT "$ENV{MUJOCO_ANDROID_ROOT}" CACHE PATH
    "Android MuJoCo install root with include/mujoco and lib/libmujoco.so")

if(NOT EXISTS "${GODOT_CPP_DIR}/SConstruct")
    message(FATAL_ERROR "godot-cpp not found at ${GODOT_CPP_DIR}. Run: make -C xr deps")
endif()
if(NOT MUJOCO_ROOT OR NOT EXISTS "${MUJOCO_ROOT}/lib/libmujoco.so")
    message(FATAL_ERROR "MuJoCo Android lib not found at ${MUJOCO_ROOT}/lib/libmujoco.so. Set MUJOCO_ANDROID_ROOT (make -C xr build-mujoco-android).")
endif()

# --- godot-cpp -------------------------------------------------------------
add_subdirectory("${GODOT_CPP_DIR}" "${GODOT_CPP_BUILD_DIR}" EXCLUDE_FROM_ALL)
set_target_properties(godot-cpp PROPERTIES
    ARCHIVE_OUTPUT_DIRECTORY "${GODOT_CPP_BUILD_DIR}/bin")

# --- retargeting toolkit (static) ------------------------------------------
# Standalone DuinoDu/retargeting repo, synced into .deps/src/retargeting and
# symlinked here as ./retargeting (scripts/sync_deps.sh retargeting). The CMake
# source is under app/; app/CMakeLists.txt includes ../cmake/nlohmann_json.cmake,
# so we point at retargeting/app and the relative include resolves via the
# whole-repo symlink. MuJoCo-only on Android (the android Pinocchio build lacks
# the MJCF parser); no demo. MUJOCO_ROOT/MUJOCO_LIB honored by app/CMakeLists.
set(RETARGETING_DIR "${CMAKE_CURRENT_SOURCE_DIR}/retargeting" CACHE PATH
    "Path to the retargeting toolkit source tree (symlink to .deps/src/retargeting)")
if(NOT EXISTS "${RETARGETING_DIR}/app/CMakeLists.txt")
    message(FATAL_ERROR "retargeting toolkit not found at ${RETARGETING_DIR}. Run: make -C xr deps  (or scripts/sync_deps.sh retargeting)")
endif()
set(RETARGETING_WITH_PINOCCHIO OFF CACHE BOOL "" FORCE)
set(RETARGETING_WITH_MUJOCO ON CACHE BOOL "" FORCE)
set(RETARGETING_BUILD_DEMO OFF CACHE BOOL "" FORCE)
set(MUJOCO_LIB "${MUJOCO_ROOT}/lib/libmujoco.so" CACHE FILEPATH "" FORCE)
add_subdirectory("${RETARGETING_DIR}/app"
    "${CMAKE_CURRENT_BINARY_DIR}/retargeting" EXCLUDE_FROM_ALL)

# --- GDExtension shared library --------------------------------------------
add_library(godot_retargeting SHARED
    src/retargeting_node.cpp
    src/register_types.cpp
)
target_include_directories(godot_retargeting PRIVATE
    src
    "${GODOT_CPP_DIR}/include"
    "${GODOT_CPP_DIR}/gen/include"
)
target_link_libraries(godot_retargeting PRIVATE
    godot-cpp
    retargeting   # propagates Eigen / nlohmann includes + libmujoco.so
    log
)
set_target_properties(godot_retargeting PROPERTIES
    OUTPUT_NAME "godot_retargeting"
    PREFIX "lib")

install(TARGETS godot_retargeting
    LIBRARY DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/../../android/build/libs/${ANDROID_ABI}")
