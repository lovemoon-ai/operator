// pinocchio_runtime.cpp — see pinocchio_runtime.h for the rationale.

#include "pinocchio_runtime.h"

#include <godot_cpp/core/class_db.hpp>

// Pinocchio macro config has to come before any Pinocchio header. We are
// linking against the Android build produced by DuinoDu/pinocchio-android,
// which compiled the library with these features turned off — keeping the
// same defines on the consumer side avoids accidental ODR drift between
// headers and the .so.
#define PINOCCHIO_WITH_HPP_FCL 0
#define PINOCCHIO_WITH_URDFDOM 0

#include <pinocchio/multibody/model.hpp>
#include <pinocchio/multibody/data.hpp>

#include <sstream>

namespace operator_xr {

godot::String PinocchioRuntime::get_pinocchio_version() const {
    // PINOCCHIO_MAJOR_VERSION / MINOR / PATCH come from
    // <pinocchio/config.hpp>, which model.hpp transitively pulls in.
    std::ostringstream oss;
    oss << PINOCCHIO_MAJOR_VERSION << "."
        << PINOCCHIO_MINOR_VERSION << "."
        << PINOCCHIO_PATCH_VERSION;
    // Bind to a named std::string so the c_str() pointer stays valid for
    // the duration of the godot::String ctor copy. oss.str().c_str() worked
    // in practice but the temporary's lifetime ends at the next sequence
    // point, which is technically a UB time-bomb.
    const std::string s = oss.str();
    return godot::String(s.c_str());
}

int PinocchioRuntime::probe_empty_model_nq() const {
    // An empty Model has only the universe joint, so nq == 0. We still
    // construct a Data from it to exercise the same allocators the FK /
    // dynamics paths will use later — any link-time mismatch with Eigen /
    // Boost surfaces here as a load-time abort instead of a confusing
    // SIGSEGV deeper in the call graph.
    pinocchio::Model model;
    pinocchio::Data data(model);
    return static_cast<int>(model.nq);
}

void PinocchioRuntime::_bind_methods() {
    using godot::ClassDB;
    using godot::D_METHOD;

    ClassDB::bind_method(D_METHOD("get_pinocchio_version"),
                         &PinocchioRuntime::get_pinocchio_version);
    ClassDB::bind_method(D_METHOD("probe_empty_model_nq"),
                         &PinocchioRuntime::probe_empty_model_nq);
}

} // namespace operator_xr
