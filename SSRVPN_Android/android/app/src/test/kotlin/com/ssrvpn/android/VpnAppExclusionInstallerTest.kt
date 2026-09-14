package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import org.junit.Assert.assertEquals

class VpnAppExclusionInstallerTest {
    @Test
    fun `domestic applications bypass the VPN ahead of manual routing`() {
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
    fun `disabled legacy flag keeps domestic apps in tunnel while adb remains bypassed`() {
        val attempted = mutableListOf<String>()

        VpnAppExclusionInstaller.install(bypassDomesticApps = false) { packageName ->
            attempted += packageName
            true
        }

        assertFalse(attempted.contains("com.ss.android.ugc.aweme"))
        assertFalse(attempted.contains("com.tencent.mm"))
        assertTrue(attempted.contains("com.android.adb"))
    }

    @Test
    fun `updated metadata replaces baseline and browsers never bypass`() {
        val packages = VpnAppExclusionInstaller.packagesFromHeader(
            listOf("# ssrvpn-direct-apps: com.example.newapp,com.example.browser")
        )
        val attempted = mutableListOf<String>()
        VpnAppExclusionInstaller.install(true, packages, setOf("com.example.browser")) {
            attempted += it
            true
        }
        assertTrue(attempted.contains("com.example.newapp"))
        assertFalse(attempted.contains("com.tencent.mm"))
        assertFalse(attempted.contains("com.example.browser"))
        assertTrue(VpnAppExclusionInstaller.packagesFromHeader(listOf("# ssrvpn-direct-apps: ")).isEmpty())
    }

    @Test(expected = IllegalArgumentException::class)
    fun `invalid exclusion metadata cannot become a VPN bypass`() {
        VpnAppExclusionInstaller.packagesFromHeader(listOf("# ssrvpn-direct-apps: com.test,PROXY"))
    }

    @Test
    fun `cold start reads the exclusion list belonging to the saved config`() {
        val file = File.createTempFile("ssrvpn-exclusions-", ".yaml")
        try {
            file.writeText("# SSRVPN\n# ssrvpn-direct-apps: com.example.saved\nfind-process-mode: strict\nmixed-port: 7890\n")
            assertEquals(listOf("com.example.saved"), VpnAppExclusionInstaller.packagesFromConfig(file))
            file.writeText("# SSRVPN\n# ssrvpn-direct-apps: \nfind-process-mode: strict\n")
            assertTrue(VpnAppExclusionInstaller.packagesFromConfig(file).isEmpty())
            file.writeText("# Legacy SSRVPN\nmixed-port: 7890\n")
            assertEquals(DomesticAppBypassPolicy.packageNames, VpnAppExclusionInstaller.packagesFromConfig(file))
        } finally {
            file.delete()
        }
    }
}
