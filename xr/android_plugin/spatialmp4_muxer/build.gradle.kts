// SpatialMP4 muxer module: wraps the patched FFmpeg native writer + its Kotlin
// JNI bridge + the SpatialMP4 box-bytes packer. Built as an Android library
// AAR so Godot can bundle it next to the provider AAR.
//
// In Stage 1 of the two-plugin split this module hosts:
//   - SpatialMp4Native (Kotlin object) -- JNI bindings to libspatialmp4_writer.
//   - SpatialMp4SideData* (Kotlin)     -- ICAM / ECAM / DSTR bytes packer.
//   - src/main/cpp/                    -- the patched-FFmpeg writer + headers.
//
// The provider module (:questcapture today) declares
//   implementation(project(":spatialmp4_muxer"))
// so its existing `SpatialMp4Native.nativeWriteRgbPacket(...)` call sites
// resolve to these classes without renaming. Stage 2 replaces those direct
// calls with the SpatialDataSink contract.
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.spatialmp4.questcapture.muxer"
    compileSdk = 35

    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
        ndk {
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_shared")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    compileOnly("org.godotengine:godot:4.5.1.stable")
    // SpatialDataSink + Intrinsics + RgbStreamConfig + PtsDomain. `api` so the
    // questcapture provider that depends on us can also see the contract types.
    api(project(":contract"))
}
