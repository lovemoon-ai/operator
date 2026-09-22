# Repo-wide Operator release version (see scripts/version.py). Sets
# OPERATOR_VERSION (full SemVer, e.g. 0.2.0-rc.1) and OPERATOR_VERSION_CORE
# (numeric part, as project(VERSION) requires). Safe to include before project().
file(STRINGS "${CMAKE_CURRENT_LIST_DIR}/../../../VERSION" OPERATOR_VERSION LIMIT_COUNT 1)
string(REGEX MATCH "^[0-9]+\\.[0-9]+\\.[0-9]+" OPERATOR_VERSION_CORE "${OPERATOR_VERSION}")
if(NOT OPERATOR_VERSION_CORE)
  message(FATAL_ERROR "Invalid Operator VERSION '${OPERATOR_VERSION}'")
endif()
