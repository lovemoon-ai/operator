// Provider-side AAR for now -- still owns the Godot Android plugin singleton
// QuestCapturePlugin (Camera2 / HEVC encoder / OpenXR clock helpers / depth
// conversion / pose write-outs). After Stage 1 the muxer's Kotlin + native
// code lives in :spatialmp4_muxer, so this module no longer carries any C++
// itself; QuestCapturePlugin still calls into SpatialMp4Native via a direct
// `implementation(project(":spatialmp4_muxer"))` dependency. Stage 2 will
// invert that path through SpatialDataSink so the provider no longer needs to
// know about the muxer's native types.
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.spatialmp4.questcapture"
    compileSdk = 35

    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
        ndk {
            abiFilters += "arm64-v8a"
        }
        // No externalNativeBuild here: every .so the writer needs is built by
        // the :spatialmp4_muxer AAR. Gradle bundles its .so into the consuming
        // app along with this AAR's classes.
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    compileOnly("org.godotengine:godot:4.5.1.stable")
    implementation("androidx.core:core-ktx:1.15.0")
    // SpatialMp4Native, SpatialMp4SideData*, and libspatialmp4_writer.so come
    // from this module. Use `api` so any consumer of questcapture transitively
    // sees the muxer's classes (matches the current monolithic AAR's behaviour
    // and lets QuestCapturePlugin's imports stay unchanged). The muxer in turn
    // re-exports the spatial_capture_contract jar, so SpatialDataSink etc. are
    // visible here too without an extra dependency line.
    api(project(":spatialmp4_muxer"))
}
