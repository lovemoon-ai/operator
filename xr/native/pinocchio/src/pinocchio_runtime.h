// pinocchio_runtime.h — Godot-facing surface of the Pinocchio GDExtension.
//
// V1 is intentionally minimal:
//   * version()             — Pinocchio library version (string)
//   * make_empty_model()    — instantiate a fresh pinocchio::Model + Data
//                             pair and return its nq (== 0 for an empty
//                             tree). Used as a smoke test from GDScript.
//
// A richer surface (FK, Jacobian, dynamics, IK) will follow once the load
// path for an app-defined model description is settled. URDF is *not*
// available — the upstream wrapper builds with BUILD_WITH_URDF_SUPPORT=OFF.

#pragma once

// RefCounted — not Object — so GDScript can use the natural
//     var rt := PinocchioRuntime.new()
// and let refcounting reclaim it. Inheriting from Object would require
// every caller to invoke rt.free() and forgetting it leaks (and any
// future Ref<PinocchioRuntime> would double-free).
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

namespace operator_xr {

class PinocchioRuntime : public godot::RefCounted {
    GDCLASS(PinocchioRuntime, godot::RefCounted)

public:
    PinocchioRuntime() = default;

    // Pinocchio's compile-time version string, e.g. "3.7.0".
    godot::String get_pinocchio_version() const;

    // Smoke test: build an empty pinocchio::Model + pinocchio::Data and
    // return Model::nq. Always 0, but proves the library + Eigen/Boost
    // linkage works at runtime.
    int probe_empty_model_nq() const;

protected:
    static void _bind_methods();
};

} // namespace operator_xr
