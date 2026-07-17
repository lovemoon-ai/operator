#include "pico_openxr_extension.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/core/memory.hpp>

using namespace godot;

static PicoOpenXRExtension *pico_openxr_singleton = nullptr;
static const char *PICO_OPENXR_SINGLETON_NAME = "PicoOpenXRBridgeNative";

static void initialize(ModuleInitializationLevel level) {
	if (level == MODULE_INITIALIZATION_LEVEL_CORE) {
		ClassDB::register_class<PicoOpenXRExtension>();
		pico_openxr_singleton = memnew(PicoOpenXRExtension);
		pico_openxr_singleton->register_extension_wrapper();
		return;
	}
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	if (pico_openxr_singleton) {
		Engine::get_singleton()->register_singleton(PICO_OPENXR_SINGLETON_NAME, pico_openxr_singleton);
	}
}

static void uninitialize(ModuleInitializationLevel level) {
	if (level == MODULE_INITIALIZATION_LEVEL_SCENE) {
		if (pico_openxr_singleton) {
			// Stop native camera/hand workers while the OpenXR session and the
			// Android media stack are still alive. The wrapper itself remains
			// owned by OpenXRAPI after register_extension_wrapper().
			pico_openxr_singleton->stop_camera_image_capture();
			Engine::get_singleton()->unregister_singleton(PICO_OPENXR_SINGLETON_NAME);
		}
		return;
	}
	if (level == MODULE_INITIALIZATION_LEVEL_CORE && pico_openxr_singleton) {
		// OpenXRAPI::cleanup_extension_wrappers() deletes registered wrappers
		// during OpenXR module teardown. Deleting it again here destroys the
		// same Object mutex twice on Godot's VkThread.
		pico_openxr_singleton = nullptr;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT pico_openxr_init(
		GDExtensionInterfaceGetProcAddress get_proc_address,
		const GDExtensionClassLibraryPtr library,
		GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init_obj(get_proc_address, library, initialization);
	init_obj.register_initializer(initialize);
	init_obj.register_terminator(uninitialize);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_CORE);
	return init_obj.init();
}
}
