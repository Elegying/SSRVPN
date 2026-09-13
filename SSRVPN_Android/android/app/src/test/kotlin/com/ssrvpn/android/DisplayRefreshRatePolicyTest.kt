package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Test

class DisplayRefreshRatePolicyTest {
    private val modes = listOf(60f, 90f, 120f, 144f)
    @Test fun respectsFixedAndAutomaticRates() {
        assertEquals(60f, preferredDisplayRefreshRate(modes, 60f, false))
        assertEquals(120f, preferredDisplayRefreshRate(modes, 120f, false))
        assertEquals(144f, preferredDisplayRefreshRate(modes, null, false))
        assertEquals(144f, preferredDisplayRefreshRate(modes, Float.NaN, false))
        assertEquals(60f, preferredDisplayRefreshRate(modes, 144f, true))
        assertEquals(0f, preferredDisplayRefreshRate(emptyList(), null, false))
        assertEquals(90f, preferredDisplayRefreshRate(listOf(90f, 120f), 60f, true))
    }
}
