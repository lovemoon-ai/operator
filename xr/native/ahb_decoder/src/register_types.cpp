// register_types.cpp — GDExtension entry point.
//
// Godot calls `ahb_decoder_init` once per scene level (CORE / SERVERS /
// SCENE / EDITOR). We only register classes at SCENE level — earlier
// levels don't have RenderingServer wired up yet.

#include "ahb_video_texture.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    ClassDB::register_class<AhbVideoTexture>();
}

static void uninitialize(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    // ClassDB::register_class is auto-cleaned by godot-cpp on shutdown.
}

extern "C" {
GDExtensionBool GDE_EXPORT ahb_decoder_init(
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
