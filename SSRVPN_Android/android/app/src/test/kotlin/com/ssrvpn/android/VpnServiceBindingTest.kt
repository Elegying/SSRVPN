package com.ssrvpn.android

import android.content.Intent
import android.net.VpnService
import org.junit.Assert.assertEquals
import org.junit.Test

class VpnServiceBindingTest {
    @Test
    fun `system binding is inherited so Android can deliver VPN revocation`() {
        val binding = SsrvpnVpnService::class.java.getMethod("onBind", Intent::class.java)
        assertEquals(VpnService::class.java, binding.declaringClass)
    }
}
