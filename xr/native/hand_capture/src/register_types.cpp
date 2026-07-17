// register_types.cpp — GDExtension entry point for hand_capture.

#include "native_body_motion_writer.h"
#include "native_hand_sampler.h"
#include "native_openxr_hand_capture.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/godot.hpp>
using namespace godot;

static NativeOpenXRHandCapture *openxr_hand_capture_singleton = nullptr;
static const char *OPENXR_HAND_CAPTURE_SINGLETON_NAME = "NativeOpenXRHandCapture";

static void initialize(ModuleInitializationLevel level) {
	if (level == MODULE_INITIALIZATION_LEVEL_CORE) {
		ClassDB::register_class<NativeOpenXRHandCapture>();
		openxr_hand_capture_singleton = memnew(NativeOpenXRHandCapture);
		openxr_hand_capture_singleton->register_extension_wrapper();
		return;
	}
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    ClassDB::register_class<NativeHandSampler>();
    ClassDB::register_class<NativeBodyMotionWriter>();
	if (openxr_hand_capture_singleton != nullptr) {
		Engine::get_singleton()->register_singleton(
				OPENXR_HAND_CAPTURE_SINGLETON_NAME, openxr_hand_capture_singleton);
	}
}

static void uninitialize(ModuleInitializationLevel level) {
	if (level == MODULE_INITIALIZATION_LEVEL_SCENE) {
		if (openxr_hand_capture_singleton != nullptr) {
			openxr_hand_capture_singleton->stop_recording();
			Engine::get_singleton()->unregister_singleton(OPENXR_HAND_CAPTURE_SINGLETON_NAME);
		}
		return;
	}
	if (level == MODULE_INITIALIZATION_LEVEL_CORE) {
		// OpenXRAPI owns wrappers registered through register_extension_wrapper().
		openxr_hand_capture_singleton = nullptr;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT hand_capture_init(
        GDExtensionInterfaceGetProcAddress get_proc_address,
        const GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization) {
    GDExtensionBinding::InitObject init_obj(get_proc_address, p_library, r_initialization);
    init_obj.register_initializer(initialize);
    init_obj.register_terminator(uninitialize);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_CORE);
    return init_obj.init();
}
}
