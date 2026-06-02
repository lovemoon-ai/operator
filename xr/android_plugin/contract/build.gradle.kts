// Pure Kotlin/JVM library — no Android dependencies, no native code, no Godot
// dependencies. Both the xr_capture_provider AAR (data producer) and the
// spatialmp4_muxer AAR (data consumer) depend on it so they can pass typed
// SpatialDataSink calls across plugin boundaries without serialising through
// GDScript on the hot path.
//
// Keep this module additive-only at the source level: new interface methods
// must ship with `default` implementations, and `CONTRACT_VERSION` bumps
// whenever a method or data class field is added. Reader/writer pairs across
// plugin versions check `SpatialDataSink.contractVersion` at bind time.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

kotlin {
    jvmToolchain(17)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
