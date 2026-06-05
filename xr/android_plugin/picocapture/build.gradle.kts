plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.spatialmp4.picocapture"
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
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    compileOnly("org.godotengine:godot:4.5.1.stable")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation(project(":capture_common"))
    api(project(":spatialmp4_muxer"))
}
