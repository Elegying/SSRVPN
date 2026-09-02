package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnAppExclusionInstallerTest {
    @Test
    fun `all user apps stay inside tunnel while adb tooling remains bypassed`() {
        val installed = setOf(
            "com.ssrvpn.android",
            "com.ss.android.ugc.aweme",
            "com.tencent.mm",
            "com.android.adb"
        )
        val attempted = mutableListOf<String>()

        VpnAppExclusionInstaller.install { packageName ->
            attempted += packageName
            packageName in installed
        }

        assertFalse(attempted.contains("com.ssrvpn.android"))
        assertFalse(attempted.contains("com.ss.android.ugc.aweme"))
        assertFalse(attempted.contains("com.tencent.mm"))
        assertTrue(attempted.contains("com.android.adb"))
    }
}
