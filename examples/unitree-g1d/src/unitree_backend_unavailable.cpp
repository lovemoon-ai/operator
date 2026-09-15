#include "operator_g1d/backend.hpp"

#include <stdexcept>

namespace operator_g1d {

std::unique_ptr<Backend> make_unitree_backend(UnitreeBackendConfig) {
  throw std::runtime_error(
      "unitree backend is not available in this build; rebuild with "
      "-DOPERATOR_G1D_WITH_UNITREE=ON using the G1-D SDK2 checkout");
}

}  // namespace operator_g1d
