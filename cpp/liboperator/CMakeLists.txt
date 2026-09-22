cmake_minimum_required(VERSION 3.16)
include("${CMAKE_CURRENT_LIST_DIR}/cmake/OperatorVersion.cmake")
project(liboperator VERSION ${OPERATOR_VERSION_CORE} LANGUAGES C CXX)

option(LIBOPERATOR_BUILD_TESTS "Build liboperator C++ tests" OFF)
set(LIBOPERATOR_LIBRARY "" CACHE FILEPATH "Path to liboperator shared/static library")
if(NOT LIBOPERATOR_LIBRARY)
  find_file(LIBOPERATOR_STATIC_LIBRARY NAMES liboperator.a PATHS
    "${CMAKE_CURRENT_LIST_DIR}/../../robot/target/release"
    "${CMAKE_CURRENT_LIST_DIR}/../../robot/target/debug"
    NO_DEFAULT_PATH)
  if(LIBOPERATOR_STATIC_LIBRARY)
    set(LIBOPERATOR_LIBRARY "${LIBOPERATOR_STATIC_LIBRARY}")
  else()
    find_library(LIBOPERATOR_DISCOVERED_LIBRARY NAMES operator PATHS
      "${CMAKE_CURRENT_LIST_DIR}/../../robot/target/release"
      "${CMAKE_CURRENT_LIST_DIR}/../../robot/target/debug"
      NO_DEFAULT_PATH)
    set(LIBOPERATOR_LIBRARY "${LIBOPERATOR_DISCOVERED_LIBRARY}")
  endif()
endif()
if(NOT LIBOPERATOR_LIBRARY)
  message(FATAL_ERROR "liboperator not found; build it with cargo build -p operator-c")
endif()
find_package(Threads REQUIRED)
add_library(operator_sdk UNKNOWN IMPORTED GLOBAL)
set_target_properties(operator_sdk PROPERTIES IMPORTED_LOCATION "${LIBOPERATOR_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/include")
target_link_libraries(operator_sdk INTERFACE Threads::Threads ${CMAKE_DL_LIBS} m)
add_library(operator::operator ALIAS operator_sdk)

if(LIBOPERATOR_BUILD_TESTS)
  enable_testing()
  add_executable(liboperator-blueprint-test tests/blueprint_publisher_test.cpp)
  target_compile_features(liboperator-blueprint-test PRIVATE cxx_std_17)
  target_link_libraries(liboperator-blueprint-test PRIVATE operator::operator)
  target_compile_definitions(liboperator-blueprint-test PRIVATE
    LIBOPERATOR_EXPECTED_VERSION="${OPERATOR_VERSION}")
  add_test(NAME liboperator-blueprint COMMAND liboperator-blueprint-test)
endif()
