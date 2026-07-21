package com.spatialmp4.capturecommon

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceIdentityTest {
    private fun classify(
        manufacturer: String,
        model: String,
        device: String,
        product: String = device,
    ): String {
        val method = DeviceIdentity.Companion::class.java.getDeclaredMethod(
            "classify",
            String::class.java,
            String::class.java,
            String::class.java,
            String::class.java,
        )
        method.isAccessible = true
        return method.invoke(DeviceIdentity.Companion, manufacturer, model, device, product) as String
    }

    @Test
    fun classifiesQuest3sBeforeQuest3() {
        assertEquals("quest3s", classify("Oculus", "Quest 3S", "panther"))
        assertEquals("quest3", classify("Oculus", "Quest 3", "eureka"))
    }

    @Test
    fun classifiesQuestFamilyByModelNotCodename() {
        assertEquals("quest3s", classify("Oculus", "Quest 3S", "unexpected_codename"))
        assertEquals("questpro", classify("Meta", "Quest Pro", "seacliff"))
        assertEquals("quest2", classify("Oculus", "Quest 2", "hollywood"))
    }

    @Test
    fun classifiesQuest3sFromPantherWhenModelIsGenericQuest() {
        assertEquals("quest3s", classify("Oculus", "Quest", "panther"))
        assertEquals("quest3s", classify("Oculus", "Quest", "unknown", "panther"))
        assertEquals("quest_unknown", classify("Oculus", "Quest", "unknown"))
    }

    @Test
    fun classifiesEveryPicoModelAsGenericVendorType() {
        assertEquals("pico", classify("Pico", "example-one", "device-one"))
        assertEquals("pico", classify("PICO", "example-two", "device-two"))
    }
}
