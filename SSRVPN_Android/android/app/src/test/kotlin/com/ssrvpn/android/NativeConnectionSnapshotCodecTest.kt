package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativeConnectionSnapshotCodecTest {
    @Test
    fun `connection metadata and credential round trip as one snapshot`() {
        val snapshot = NativeConnectionSnapshot(
            configDir = "/data/user/0/com.ssrvpn/files/ssrvpn",
            configPath = "/data/user/0/com.ssrvpn/files/ssrvpn/config.yaml",
            apiPort = 9090,
            apiSecret = "secret-value",
            selectedNodeName = "Tokyo"
        )

        assertEquals(snapshot, NativeConnectionSnapshotCodec.decode(
            NativeConnectionSnapshotCodec.encode(snapshot)
        ))
    }

    @Test
    fun `invalid snapshots are rejected before a cold start`() {
        assertNull(NativeConnectionSnapshotCodec.decode(byteArrayOf(1, 2, 3)))
        assertNull(
            NativeConnectionSnapshotCodec.decode(
                NativeConnectionSnapshotCodec.encode(
                    NativeConnectionSnapshot("", "config.yaml", 9090, "secret", null)
                )
            )
        )
    }
}
