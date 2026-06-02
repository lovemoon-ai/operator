// JNI bridge: Kotlin's KotlinVideoDecoderPlugin calls
//   external fun nativeImportAhb(buffer: HardwareBuffer, decodedNs: Long)
// which lands here. We unwrap the AHardwareBuffer pointer (refcount-bumped
// by AHardwareBuffer_fromHardwareBuffer) and hand it to the singleton
// AhbVideoTexture.
//
// The Kotlin side is responsible for keeping a stable reference to the
// AhbVideoTexture (via Engine.get_singleton or by passing the GDScript
// instance into a registration call). We use a static pointer here for
// simplicity — only one AhbVideoTexture is alive at a time in the
// scene.

#include "ahb_video_texture.h"

#include <android/hardware_buffer_jni.h>
#include <android/log.h>
#include <jni.h>

#include <atomic>

#define LOG_TAG "AhbBridge"
#define LOGI(fmt, ...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, fmt, ##__VA_ARGS__)
#define LOGW(fmt, ...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, fmt, ##__VA_ARGS__)

static std::atomic<godot::AhbVideoTexture *> g_active_texture{nullptr};

namespace godot {
// Called from AhbVideoTexture::AhbVideoTexture / destructor to register
// the singleton. Definition lives in ahb_video_texture.cpp once wired
// up; declared here so this file compiles standalone.
void ahb_register_active(AhbVideoTexture *tex);
void ahb_unregister_active(AhbVideoTexture *tex);
} // namespace godot

extern "C" {

// Matches:
//   package com.godot.game.video
//   class KotlinVideoDecoderPlugin {
//       external fun nativeImportAhb(buffer: HardwareBuffer, decodedNs: Long)
//   }
JNIEXPORT void JNICALL
Java_com_godot_game_video_KotlinVideoDecoderPlugin_nativeImportAhb(
        JNIEnv *env,
        jobject /* thiz */,
        jobject hardware_buffer,
        jlong decoded_ns) {
    if (hardware_buffer == nullptr) {
        return;
    }
    AHardwareBuffer *ahb = AHardwareBuffer_fromHardwareBuffer(env, hardware_buffer);
    if (ahb == nullptr) {
        LOGW("AHardwareBuffer_fromHardwareBuffer returned null");
        return;
    }
    // fromHardwareBuffer does NOT bump the refcount — we have to.
    AHardwareBuffer_acquire(ahb);

    godot::AhbVideoTexture *tex = g_active_texture.load(std::memory_order_acquire);
    if (tex == nullptr) {
        LOGW("nativeImportAhb called with no active texture; dropping frame");
        AHardwareBuffer_release(ahb);
        return;
    }
    tex->push_buffer(ahb, (int64_t)decoded_ns);
}

} // extern "C"

// Visible to the GDExtension class so it can self-register.
namespace godot {
void ahb_register_active(AhbVideoTexture *tex) {
    g_active_texture.store(tex, std::memory_order_release);
}
void ahb_unregister_active(AhbVideoTexture *tex) {
    AhbVideoTexture *expected = tex;
    g_active_texture.compare_exchange_strong(expected, nullptr,
        std::memory_order_acq_rel);
}
} // namespace godot
