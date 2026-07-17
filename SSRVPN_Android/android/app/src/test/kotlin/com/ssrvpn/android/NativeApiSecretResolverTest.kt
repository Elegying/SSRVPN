package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Test

class NativeApiSecretResolverTest {
    @Test
    fun `explicit service secret wins over the stored fallback`() {
        assertEquals(
            "intent-secret",
            NativeApiSecretResolver.resolve("intent-secret", "stored-secret")
        )
    }

    @Test
    fun `tile and sticky restarts use the secure stored secret`() {
        assertEquals(
            "stored-secret",
            NativeApiSecretResolver.resolve(null, "stored-secret")
        )
        assertEquals(
            "stored-secret",
            NativeApiSecretResolver.resolve("", "stored-secret")
        )
    }

    @Test
    fun `missing secrets stay empty without inventing credentials`() {
        assertEquals("", NativeApiSecretResolver.resolve(null, null))
    }
}
