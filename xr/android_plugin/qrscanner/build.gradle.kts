// Godot Android plugin: QRScannerPlugin.
//
// Camera2 capture loop + ZXing decode for in-headset QR scanning. Used by
// xr/scripts/ego_qr_scanner.gd to populate the Ego capture-settings panel's
// Upload URL field from the web app's `/connect` QR codes.
//
// Independent module: no dependency on questcapture / spatialmp4_muxer.
// Decode is pure Java (zxing-core), no native code. AAR is small (~ 300 KB).
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.lovemoon.qrscanner"
    compileSdk = 35

    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // JVM unit tests — pure ZXing decode roundtrip, no Android dep.
    // Runs via `gradle :qrscanner:test`. Instrumented Camera2 tests
    // would need a connected device and are out of scope here.
    testOptions {
        unitTests {
            isReturnDefaultValues = true
        }
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    compileOnly("org.godotengine:godot:4.5.1.stable")
    implementation("androidx.core:core-ktx:1.15.0")

    // Pure-Java ZXing core. Apache-2.0, no transitive deps, ~ 250 KB.
    // We use zxing-core directly (not the camera-helper "android-core" wrapper)
    // because we own the Camera2 lifecycle and don't want the wrapper's
    // Activity-aware orientation handling.
    implementation("com.google.zxing:core:3.5.3")

    testImplementation("junit:junit:4.13.2")
    // No mockito etc. — the decode-path test only needs ZXing + JUnit.
}

tasks.register<Copy>("copyRuntimeDependencies") {
    from(configurations.getByName("releaseRuntimeClasspath"))
    include("core-*.jar")
    into(layout.buildDirectory.dir("outputs/runtime-libs"))
}
