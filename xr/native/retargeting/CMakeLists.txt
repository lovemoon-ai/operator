cmake_minimum_required(VERSION 3.16)
project(retargeting CXX)

# Two-layer retargeting toolkit for teleoperation:
#   * business layer  : whole-body / upper-body / hand scenarios
#   * algorithm layer : modular retargeting algorithms (GMR first)
#
# Builds two ways:
#   * desktop (host): Eigen + nlohmann-json + Pinocchio + (optional) MuJoCo.
#       cmake -S . -B build && cmake --build build
#   * Android (NDK) : Pinocchio-only, cross-compiled against the pinocchio
#       Android install tree. Driven by build_android.sh (sets the toolchain +
#       CMAKE_PREFIX_PATH); MuJoCo is forced off there.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(RETARGETING_IS_ANDROID OFF)
if(CMAKE_SYSTEM_NAME STREQUAL "Android")
  set(RETARGETING_IS_ANDROID ON)
endif()

# Kinematics backends. Pinocchio is the desktop/VR default; MuJoCo is the
# desktop reference cross-check and the on-device backend (the Android Pinocchio
# build is core-only without the MJCF parser, so on Android we ship MuJoCo,
# which loads MJCF natively). At least one must be enabled.
#   - Desktop default : Pinocchio ON, MuJoCo ON
#   - Android (build_android.sh) : Pinocchio OFF, MuJoCo ON
option(RETARGETING_WITH_PINOCCHIO "Build the Pinocchio kinematics backend" ON)
option(RETARGETING_WITH_MUJOCO "Build the MuJoCo kinematics backend" ON)
option(RETARGETING_BUILD_DEMO "Build the upper-body validation demo" ON)
if(RETARGETING_IS_ANDROID)
  set(RETARGETING_WITH_PINOCCHIO OFF CACHE BOOL "" FORCE)  # android pinocchio has no MJCF parser
endif()
if(NOT RETARGETING_WITH_PINOCCHIO AND NOT RETARGETING_WITH_MUJOCO)
  message(FATAL_ERROR "Enable at least one of RETARGETING_WITH_PINOCCHIO / RETARGETING_WITH_MUJOCO")
endif()

if(NOT RETARGETING_IS_ANDROID)
  list(APPEND CMAKE_PREFIX_PATH "/opt/homebrew")
  # homebrew Boost 1.90's `system` is header-only; prefer Boost's config package.
  set(CMAKE_FIND_PACKAGE_PREFER_CONFIG TRUE)
  if(EXISTS "/opt/homebrew/lib/cmake/Boost-1.90.0")
    set(Boost_DIR "/opt/homebrew/lib/cmake/Boost-1.90.0")
  endif()
endif()

find_package(Eigen3 REQUIRED)
if(RETARGETING_WITH_PINOCCHIO)
  find_package(pinocchio REQUIRED)
endif()

# nlohmann-json is header-only. We vendor it under third_party/nlohmann and use
# that copy directly. This keeps the include set self-contained and, crucially,
# avoids putting a broad host include dir (e.g. /opt/homebrew/include) on the
# compile line — that directory also contains host Pinocchio headers, which
# would shadow the Android install's headers during cross-compilation.
add_library(nlohmann_json INTERFACE)
add_library(nlohmann_json::nlohmann_json ALIAS nlohmann_json)
target_include_directories(nlohmann_json INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
message(STATUS "nlohmann-json: vendored (third_party/nlohmann)")

set(RETARGETING_SOURCES
  src/core/lie.cpp
  src/core/box_qp.cpp
  src/algorithms/algorithm_registry.cpp
  src/algorithms/builtins.cpp
  src/algorithms/gmr/gmr_solver.cpp
  src/algorithms/gmr/gmr_algorithm.cpp
  src/business/retargeter.cpp
  src/sources/quest3_source.cpp
)
if(RETARGETING_WITH_PINOCCHIO)
  list(APPEND RETARGETING_SOURCES src/core/pinocchio_backend.cpp)
endif()

if(RETARGETING_WITH_MUJOCO)
  # MuJoCo from the project's Python wheel (libmujoco + C headers).
  if(NOT MUJOCO_ROOT)
    set(MUJOCO_ROOT "$ENV{HOME}/.cache/install-x/GMR/.venv/lib/python3.10/site-packages/mujoco")
  endif()
  # build_android.sh passes -DMUJOCO_LIB explicitly (find_library then no-ops);
  # on desktop we locate it under the wheel dir or an install's lib/.
  find_library(MUJOCO_LIB NAMES mujoco mujoco.3.9.0 libmujoco.3.9.0
    PATHS "${MUJOCO_ROOT}" "${MUJOCO_ROOT}/lib" NO_DEFAULT_PATH)
  if(NOT MUJOCO_LIB)
    file(GLOB _mj_dylib "${MUJOCO_ROOT}/libmujoco*.dylib" "${MUJOCO_ROOT}/lib/libmujoco.so*")
    if(_mj_dylib)
      list(GET _mj_dylib 0 MUJOCO_LIB)
    endif()
  endif()
  if(MUJOCO_LIB)
    message(STATUS "MuJoCo lib: ${MUJOCO_LIB}")
    list(APPEND RETARGETING_SOURCES src/core/mujoco_backend.cpp)
  else()
    message(WARNING "MuJoCo not found under ${MUJOCO_ROOT}; building Pinocchio-only.")
    set(RETARGETING_WITH_MUJOCO OFF)
  endif()
endif()

add_library(retargeting STATIC ${RETARGETING_SOURCES})
target_include_directories(retargeting PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/include
  ${CMAKE_CURRENT_SOURCE_DIR}/src
  ${CMAKE_CURRENT_SOURCE_DIR}/src/core)
target_link_libraries(retargeting PUBLIC
  Eigen3::Eigen nlohmann_json::nlohmann_json)

if(RETARGETING_WITH_PINOCCHIO)
  target_link_libraries(retargeting PUBLIC pinocchio::pinocchio)
else()
  target_compile_definitions(retargeting PUBLIC RETARGETING_NO_PINOCCHIO=1)
endif()

if(RETARGETING_WITH_MUJOCO)
  target_include_directories(retargeting PUBLIC "${MUJOCO_ROOT}/include")
  target_link_libraries(retargeting PUBLIC "${MUJOCO_LIB}")
else()
  target_compile_definitions(retargeting PUBLIC RETARGETING_NO_MUJOCO=1)
endif()

if(RETARGETING_BUILD_DEMO)
  add_executable(upper_body_demo apps/upper_body_demo.cpp)
  target_link_libraries(upper_body_demo PRIVATE retargeting)

  # The MuJoCo wheel dylib records its install name as a framework path but ships
  # as a flat dylib; repoint the dependency so the binary runs without a
  # framework layout or DYLD_LIBRARY_PATH (matches the GMR port).
  if(APPLE AND RETARGETING_WITH_MUJOCO)
    get_filename_component(_mj_name "${MUJOCO_LIB}" NAME)
    add_custom_command(TARGET upper_body_demo POST_BUILD
      COMMAND install_name_tool -change
        "@rpath/mujoco.framework/Versions/A/${_mj_name}" "${MUJOCO_LIB}"
        "$<TARGET_FILE:upper_body_demo>"
      VERBATIM)
  endif()
endif()

if(RETARGETING_BUILD_DEMO)
  add_executable(retarget_probe apps/retarget_probe.cpp)
  target_link_libraries(retarget_probe PRIVATE retargeting)
  if(APPLE AND RETARGETING_WITH_MUJOCO)
    get_filename_component(_mj_name "${MUJOCO_LIB}" NAME)
    add_custom_command(TARGET retarget_probe POST_BUILD
      COMMAND install_name_tool -change
        "@rpath/mujoco.framework/Versions/A/${_mj_name}" "${MUJOCO_LIB}"
        "$<TARGET_FILE:retarget_probe>" VERBATIM)
  endif()
endif()

if(RETARGETING_BUILD_DEMO)
  add_executable(retarget_align apps/retarget_align.cpp)
  target_link_libraries(retarget_align PRIVATE retargeting)
  if(APPLE AND RETARGETING_WITH_MUJOCO)
    get_filename_component(_mj_name "${MUJOCO_LIB}" NAME)
    add_custom_command(TARGET retarget_align POST_BUILD
      COMMAND install_name_tool -change
        "@rpath/mujoco.framework/Versions/A/${_mj_name}" "${MUJOCO_LIB}"
        "$<TARGET_FILE:retarget_align>" VERBATIM)
  endif()
endif()

if(RETARGETING_BUILD_DEMO)
  add_executable(spatialmp4_to_g1 apps/spatialmp4_to_g1.cpp)
  target_link_libraries(spatialmp4_to_g1 PRIVATE retargeting)
  if(APPLE AND RETARGETING_WITH_MUJOCO)
    get_filename_component(_mj_name "${MUJOCO_LIB}" NAME)
    add_custom_command(TARGET spatialmp4_to_g1 POST_BUILD
      COMMAND install_name_tool -change
        "@rpath/mujoco.framework/Versions/A/${_mj_name}" "${MUJOCO_LIB}"
        "$<TARGET_FILE:spatialmp4_to_g1>" VERBATIM)
  endif()
endif()
