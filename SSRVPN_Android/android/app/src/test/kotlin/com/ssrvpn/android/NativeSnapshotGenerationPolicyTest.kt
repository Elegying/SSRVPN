package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeSnapshotGenerationPolicyTest {
    @Test
    fun `a stale clear cannot remove a newer snapshot generation`() {
        assertFalse(
            NativeSnapshotGenerationPolicy.shouldClear(
                expectedGeneration = "old-generation",
                currentGeneration = "new-generation"
            )
        )
        assertTrue(
            NativeSnapshotGenerationPolicy.shouldClear(
                expectedGeneration = "current-generation",
                currentGeneration = "current-generation"
            )
        )
    }
}
