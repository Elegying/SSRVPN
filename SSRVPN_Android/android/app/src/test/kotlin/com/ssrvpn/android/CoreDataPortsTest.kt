package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Test

class CoreDataPortsTest {
    @Test
    fun `reads configured mixed and socks ports`() {
        assertEquals(
            listOf(17890, 17891),
            CoreDataPorts.fromPreferences(
                mapOf(
                    "flutter.proxyPort" to 17890L,
                    "flutter.socksPort" to 17891L,
                )
            )
        )
    }

    @Test
    fun `invalid values fall back to default data ports`() {
        assertEquals(
            listOf(7890, 7891),
            CoreDataPorts.fromPreferences(
                mapOf(
                    "flutter.proxyPort" to 0L,
                    "flutter.socksPort" to "invalid",
                )
            )
        )
    }

    @Test
    fun `duplicate ports are checked only once`() {
        assertEquals(
            listOf(17890),
            CoreDataPorts.fromPreferences(
                mapOf(
                    "flutter.proxyPort" to 17890,
                    "flutter.socksPort" to 17890,
                )
            )
        )
    }
}
