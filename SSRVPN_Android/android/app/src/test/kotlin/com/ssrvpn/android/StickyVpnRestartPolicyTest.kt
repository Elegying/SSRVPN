package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StickyVpnRestartPolicyTest {
    @Test
    fun `manual disconnect rejects only system sticky restart`() {
        assertFalse(
            StickyVpnRestartPolicy.shouldAccept(
                hasExplicitIntent = false,
                manuallyStopped = true
            )
        )
        assertTrue(
            StickyVpnRestartPolicy.shouldAccept(
                hasExplicitIntent = true,
                manuallyStopped = true
            )
        )
    }

    @Test
    fun `active desired connection keeps sticky recovery compatible`() {
        assertTrue(
            StickyVpnRestartPolicy.shouldAccept(
                hasExplicitIntent = false,
                manuallyStopped = false
            )
        )
    }
}
