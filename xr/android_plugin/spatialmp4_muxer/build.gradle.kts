// SpatialMP4 muxer module: wraps the patched FFmpeg native writer + its Kotlin
// JNI bridge + the SpatialMP4 box-bytes packer. Built as an Android library
// AAR so Godot can bundle it next to the provider AAR.
//
// In Stage 1 of the two-plugin split this module hosts:
//   - SpatialMp4Native (Kotlin object) -- JNI bindings to libspatialmp4_writer.
//   - SpatialMp4SideData* (Kotlin)     -- ICAM / ECAM / DSTR bytes packer.
//   - src/main/cpp/                    -- the patched-FFmpeg writer + headers.
//
// Provider modules depend on :spatialmp4_muxer through the SpatialDataSink
// contract and the shared side-data packer, without depending on each other.
import java.io.File

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

val repoRoot = rootProject.projectDir.parentFile.parentFile
// Mirror the Make/shell layer: OPERATOR_DEPS_CACHE_ROOT (env) > <repoRoot>/.deps.
// Without this, `make build-ffmpeg` would land libavformat.a in the shared
// cache but Gradle would still resolve -DFFMPEG_BUILD_DIR against
// <worktree>/.deps, tripping the EXISTS check in src/main/cpp/CMakeLists.txt.
val depsCacheRoot: File = System.getenv("OPERATOR_DEPS_CACHE_ROOT")
    ?.takeIf { it.isNotBlank() }
    ?.let { File(it) }
    ?: repoRoot.resolve(".deps")
val ffmpegBuildDir = depsCacheRoot.resolve("build/ffmpeg")
val ffmpegRoot = ffmpegBuildDir.resolve("arm64-v8a/install")

android {
    namespace = "com.spatialmp4.muxer"
    compileSdk = 35

    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
        ndk {
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    "-DFFMPEG_BUILD_DIR=${ffmpegBuildDir.absolutePath}",
                    "-DFFMPEG_ROOT=${ffmpegRoot.absolutePath}",
                )
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
