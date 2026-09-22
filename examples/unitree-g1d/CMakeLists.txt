cmake_minimum_required(VERSION 3.16)

include(${CMAKE_CURRENT_SOURCE_DIR}/../../cpp/liboperator/cmake/OperatorVersion.cmake)
project(operator_g1d_client VERSION ${OPERATOR_VERSION_CORE} LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(OPERATOR_G1D_BUILD_TESTS "Build offline unit and protocol tests" ON)
option(OPERATOR_G1D_WITH_UNITREE "Build the Unitree SDK2 hardware backend" ON)
set(
  UNITREE_SDK2_ROOT
  "/home/unitree/unitree_sdk2"
  CACHE PATH
  "Path to a unitree_sdk2 source checkout, or leave empty for find_package(unitree_sdk2)"
)

find_package(Threads REQUIRED)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../cpp/liboperator
  ${CMAKE_CURRENT_BINARY_DIR}/liboperator)

set(OPERATOR_G1D_CORE_SOURCES
  src/backend.cpp
  src/controller.cpp
  src/protocol.cpp
  src/socket_server.cpp
)

if(UNITREE_SDK2_ROOT AND EXISTS "${UNITREE_SDK2_ROOT}/include/unitree/robot/channel/channel_factory.hpp")
  set(UNITREE_SDK2_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
  find_library(
    UNITREE_SDK2_LIBRARY
    NAMES unitree_sdk2
    PATHS "${UNITREE_SDK2_ROOT}/lib/${UNITREE_SDK2_ARCH}"
    NO_DEFAULT_PATH
    REQUIRED
  )
  find_library(
    UNITREE_DDS_C_LIBRARY
    NAMES ddsc
    PATHS "${UNITREE_SDK2_ROOT}/thirdparty/lib/${UNITREE_SDK2_ARCH}"
    NO_DEFAULT_PATH
    REQUIRED
  )
  find_library(
    UNITREE_DDS_CXX_LIBRARY
    NAMES ddscxx
    PATHS "${UNITREE_SDK2_ROOT}/thirdparty/lib/${UNITREE_SDK2_ARCH}"
    NO_DEFAULT_PATH
    REQUIRED
  )

  add_library(operator_unitree_sdk2 STATIC IMPORTED GLOBAL)
  set_target_properties(operator_unitree_sdk2 PROPERTIES
    IMPORTED_LOCATION "${UNITREE_SDK2_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${UNITREE_SDK2_ROOT}/include;${UNITREE_SDK2_ROOT}/thirdparty/include;${UNITREE_SDK2_ROOT}/thirdparty/include/ddscxx"
  )
  target_link_libraries(operator_unitree_sdk2 INTERFACE
    "${UNITREE_DDS_C_LIBRARY}"
    "${UNITREE_DDS_CXX_LIBRARY}"
    Threads::Threads
  )
  set(OPERATOR_UNITREE_TARGET operator_unitree_sdk2)
  set(CMAKE_BUILD_RPATH "${UNITREE_SDK2_ROOT}/thirdparty/lib/${UNITREE_SDK2_ARCH}")
else()
  find_package(unitree_sdk2 REQUIRED CONFIG)
  set(OPERATOR_UNITREE_TARGET unitree_sdk2)
endif()

if(OPERATOR_G1D_WITH_UNITREE)
  if(UNITREE_SDK2_ROOT AND
     NOT EXISTS "${UNITREE_SDK2_ROOT}/include/unitree/robot/g1/agv/g1_agv_client.hpp")
    message(FATAL_ERROR
      "UNITREE_SDK2_ROOT does not contain the G1-D AGV client header; "
      "use the SDK deployed on the G1-D or configure with -DOPERATOR_G1D_WITH_UNITREE=OFF"
    )
  endif()
  list(APPEND OPERATOR_G1D_CORE_SOURCES src/unitree_backend.cpp)
else()
  list(APPEND OPERATOR_G1D_CORE_SOURCES src/unitree_backend_unavailable.cpp)
endif()

add_library(operator_g1d_core ${OPERATOR_G1D_CORE_SOURCES})
target_include_directories(operator_g1d_core PUBLIC include)
target_link_libraries(operator_g1d_core PUBLIC ${OPERATOR_UNITREE_TARGET} Threads::Threads)
target_compile_options(operator_g1d_core PRIVATE -Wall -Wextra -Wpedantic)

add_executable(operator-g1d-client src/main.cpp)
target_link_libraries(operator-g1d-client PRIVATE operator_g1d_core operator::operator)

if(OPERATOR_G1D_BUILD_TESTS)
  enable_testing()
  find_package(Python3 COMPONENTS Interpreter REQUIRED)

  add_executable(operator-g1d-tests tests/test_main.cpp)
  target_link_libraries(operator-g1d-tests PRIVATE operator_g1d_core)
  add_test(NAME operator-g1d-unit COMMAND operator-g1d-tests)

  add_test(
    NAME operator-g1d-protocol-smoke
    COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/protocol_smoke.py
      $<TARGET_FILE:operator-g1d-client>
      ${CMAKE_CURRENT_SOURCE_DIR}/config/unitree_g1d_descriptor.json
      ${CMAKE_CURRENT_SOURCE_DIR}/config/unitree_g1d_blueprint.json
      ${CMAKE_CURRENT_SOURCE_DIR}/../../specs/blueprint/v1.json
  )
  add_test(
    NAME operator-g1d-camera-source
    COMMAND ${Python3_EXECUTABLE}
      ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_camera_source.py
      ${CMAKE_CURRENT_SOURCE_DIR}/scripts/teleimager_h264.py
  )
endif()
