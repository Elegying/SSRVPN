package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnAppExclusionInstallerTest {
    @Test
    fun `vpn app stays inside tunnel while domestic and adb apps remain bypassed`() {
        val installed = setOf(
            "com.ssrvpn.android",
            "com.ss.android.ugc.aweme",
            "com.tencent.mm",
            "com.android.adb"
        )
        val attempted = mutableListOf<String>()

        VpnAppExclusionInstaller.install(bypassDomesticApps = true) { packageName ->
            attempted += packageName
            packageName in installed
        }

        assertFalse(attempted.contains("com.ssrvpn.android"))
        assertTrue(attempted.contains("com.ss.android.ugc.aweme"))
        assertTrue(attempted.contains("com.tencent.mm"))
        assertTrue(attempted.contains("com.android.adb"))
    }

    @Test
    fun `global mode keeps domestic apps in tunnel while adb remains bypassed`() {
        val attempted = mutableListOf<String>()

        VpnAppExclusionInstaller.install(bypassDomesticApps = false) { packageName ->
            attempted += packageName
            true
        }

        assertFalse(attempted.contains("com.ss.android.ugc.aweme"))
        assertFalse(attempted.contains("com.tencent.mm"))
        assertTrue(attempted.contains("com.android.adb"))
    }
}
