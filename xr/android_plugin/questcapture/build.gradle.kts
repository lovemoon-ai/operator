// Provider-side AAR for now -- still owns the Godot Android plugin singleton
// QuestCapturePlugin (Camera2 / HEVC encoder / OpenXR clock helpers / depth
// conversion / pose write-outs). The muxer's Kotlin + native code lives in
// :spatialmp4_muxer, so this module no longer carries any C++ itself.
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
    implementation(project(":capture_common"))
    // SpatialMp4MuxerPlugin, SpatialMp4SideData*, and libspatialmp4_writer.so
    // come from the standalone muxer module.
    api(project(":spatialmp4_muxer"))
}
