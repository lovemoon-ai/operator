package com.spatialmp4.questcapture

import android.os.Build

/**
 * Headset identity captured at session start, so every produced spatial mp4
 * (and the JSON manifest sidecar) records which device the data came from.
 *
 * `type` is a normalised short id ("pico4_ultra", "quest3", "quest3s",
 * "questpro", "vivexr_elite", ...). Unknown devices fall back to a slugified
 * version of Build.MODEL so we never lose information. `model` and
 * `manufacturer` are the raw Build.* strings -- downstream tooling can pick
 * whichever is convenient.
 *
 * The values are read once from android.os.Build, which is the standard
 * system surface for identifying a device on Android-based XR runtimes
 * (Quest's HorizonOS is Android, Pico's PICO OS is Android, VIVE XR is
 * Android). XR runtimes do not publish a "headset model" capability beyond
 * this, so Build.MANUFACTURER + Build.MODEL + Build.DEVICE is the canonical
 * answer.
 */
data class DeviceIdentity(
    val type: String,
    val model: String,
    val manufacturer: String,
    val device: String
) {
    companion object {
        fun detect(): DeviceIdentity {
            val manufacturer = (Build.MANUFACTURER ?: "").trim()
            val model = (Build.MODEL ?: "").trim()
            val device = (Build.DEVICE ?: "").trim()
            val product = (Build.PRODUCT ?: "").trim()
            return DeviceIdentity(
                type = classify(manufacturer, model, device, product),
                model = model,
                manufacturer = manufacturer,
                device = device
            )
        }

        /**
         * Map raw Build.* fields to a stable short identifier. The mappings
         * cover the headsets we currently ship for (Meta Quest family, Pico
         * 4 family). Add a new branch here when a new platform is supported.
         */
        private fun classify(
            manufacturer: String,
            model: String,
            device: String,
            @Suppress("UNUSED_PARAMETER") product: String
        ): String {
            val mfg = manufacturer.lowercase()
            val mdl = model.lowercase()

            // ---- Meta Quest family. Build.MANUFACTURER is "Oculus" on Quest
            // 1/2/3/Pro and "Meta" on newer firmware; check both. We classify
            // by MODEL only -- Build.DEVICE codenames published on the web
            // (panther / eureka / seacliff / hollywood / ...) are reported
            // inconsistently across sources and an actual Quest 3 in this
            // worktree showed device=eureka, which contradicts several
            // public roundups. MODEL ("Quest 3", "Quest 3S", "Quest Pro",
            // "Quest 2") is the only field we trust to be stable.
            if (mfg.contains("oculus") || mfg.contains("meta")) {
                // Quest 3S must be checked before Quest 3 because "quest 3"
                // is a substring of "quest 3s".
                if (mdl.contains("quest 3s")) {
                    return "quest3s"
                }
                if (mdl.contains("quest 3")) {
                    return "quest3"
                }
                if (mdl.contains("quest pro")) {
                    return "questpro"
                }
                if (mdl.contains("quest 2")) {
                    return "quest2"
                }
                if (mdl.contains("quest")) {
                    return "quest_unknown"
                }
                return "meta_unknown"
            }

            // ---- Pico family. Build.MANUFACTURER is "Pico" / "PICO". We
            // classify by MODEL only -- Pico's Build.DEVICE / Build.PRODUCT
            // codenames vary across firmware revisions and aren't publicly
            // documented, so MODEL is the only field we trust.
            if (mfg.contains("pico")) {
                // Pico's MODEL is sometimes the marketing name ("Pico 4 Ultra")
                // and sometimes the internal model number (e.g. "A9210" for
                // Pico 4 Ultra, "A8110"/"A8150" for Pico 4). Both forms are
                // checked here so either lands in the right classifier branch.
                if (mdl.contains("4 ultra") || mdl.contains("4u") ||
                    mdl.contains("a9210") || mdl.contains("a8210")) {
                    return "pico4_ultra"
                }
                if (mdl.contains("4 pro")) {
                    return "pico4_pro"
                }
                if (mdl.contains("4 enterprise") || mdl.contains("4e")) {
                    return "pico4_enterprise"
                }
                if (mdl.contains("pico 4") || mdl.contains("a8110") || mdl.contains("a8150")) {
                    return "pico4"
                }
                if (mdl.contains("g3") || mdl.contains("pico g3")) {
                    return "pico_g3"
                }
                if (mdl.contains("neo 3")) {
                    return "pico_neo3"
                }
                return slug(model.ifEmpty { "pico_unknown" })
            }

            // ---- HTC Vive XR
            if (mfg.contains("htc") || mdl.contains("vive xr") || mdl.contains("vive focus")) {
                if (mdl.contains("xr elite")) return "vive_xr_elite"
                if (mdl.contains("focus 3")) return "vive_focus3"
                return slug(model.ifEmpty { "htc_unknown" })
            }

            // Fall back to a stable slug of MODEL so we still capture *something*.
            return slug(model.ifEmpty { device.ifEmpty { "unknown" } })
        }

        private fun slug(raw: String): String {
            val builder = StringBuilder()
            for (ch in raw.lowercase()) {
                if (ch.isLetterOrDigit()) {
                    builder.append(ch)
                } else if (ch == ' ' || ch == '-' || ch == '_') {
                    if (builder.isNotEmpty() && builder.last() != '_') {
                        builder.append('_')
                    }
                }
            }
            while (builder.isNotEmpty() && builder.last() == '_') {
                builder.deleteCharAt(builder.length - 1)
            }
            return if (builder.isEmpty()) "unknown" else builder.toString()
        }
    }
}
