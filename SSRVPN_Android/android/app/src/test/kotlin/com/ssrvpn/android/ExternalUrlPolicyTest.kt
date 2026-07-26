package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ExternalUrlPolicyTest {
    @Test
    fun `only absolute HTTP and HTTPS links may leave the app`() {
        assertEquals(
            "https://example.com/releases/latest",
            ExternalUrlPolicy.normalizedHttpUrl(
                " https://example.com/releases/latest "
            )
        )
        assertEquals(
            "http://example.com/help",
            ExternalUrlPolicy.normalizedHttpUrl("http://example.com/help")
        )

        for (url in listOf(
            "file:///data/user/0/com.ssrvpn/files/private",
            "content://com.ssrvpn.private/state",
            "intent://example.com/#Intent;scheme=https;end",
            "javascript:alert(1)",
            "https://user:password@example.com/",
            "/relative/path",
            "https:///missing-host"
        )) {
            assertNull(url, ExternalUrlPolicy.normalizedHttpUrl(url))
        }
    }
}
