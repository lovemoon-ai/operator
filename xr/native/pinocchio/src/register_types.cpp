// register_types.cpp — GDExtension entry point for libpinocchio_gd.so.
//
// Mirrors native/ahb_decoder/src/register_types.cpp. All Pinocchio-related
// classes register at SCENE level — Pinocchio doesn't depend on
// RenderingServer, but binding earlier complicates teardown ordering.

#include "pinocchio_runtime.h"
#include "pinocchio_model.h"
#include "pinocchio_data.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    ClassDB::register_class<operator_xr::PinocchioRuntime>();
    ClassDB::register_class<operator_xr::PinocchioModel>();
    ClassDB::register_class<operator_xr::PinocchioData>();
}

static void uninitialize(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    // ClassDB::register_class is auto-cleaned by godot-cpp on shutdown.
}

extern "C" {
GDExtensionBool GDE_EXPORT pinocchio_gd_init(
        GDExtensionInterfaceGetProcAddress get_proc_address,
        const GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization) {
    GDExtensionBinding::InitObject init_obj(get_proc_address, p_library, r_initialization);
    init_obj.register_initializer(initialize);
    init_obj.register_terminator(uninitialize);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
