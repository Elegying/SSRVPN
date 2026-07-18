package com.ssrvpn.android

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
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
    fun `accepted large node names round trip without modified UTF limits`() {
        val asciiName = "n".repeat(64 * 1024)
        val multibyteName = "节".repeat(64 * 1024)

        listOf(asciiName, multibyteName).forEach { nodeName ->
            val snapshot = NativeConnectionSnapshot(
                configDir = "/data/user/0/com.ssrvpn/files/ssrvpn",
                configPath = "/data/user/0/com.ssrvpn/files/ssrvpn/config.yaml",
                apiPort = 9090,
                apiSecret = "secret-value",
                selectedNodeName = nodeName
            )

            assertEquals(
                snapshot,
                NativeConnectionSnapshotCodec.decode(
                    NativeConnectionSnapshotCodec.encode(snapshot)
                )
            )
        }
    }

    @Test
    fun `legacy version one snapshot remains readable after codec upgrade`() {
        val snapshot = NativeConnectionSnapshot(
            configDir = "/data/user/0/com.ssrvpn/files/ssrvpn",
            configPath = "/data/user/0/com.ssrvpn/files/ssrvpn/config.yaml",
            apiPort = 9090,
            apiSecret = "legacy-secret",
            selectedNodeName = "Legacy Tokyo"
        )

        assertEquals(snapshot, NativeConnectionSnapshotCodec.decode(encodeLegacy(snapshot)))
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

    private fun encodeLegacy(snapshot: NativeConnectionSnapshot): ByteArray =
        ByteArrayOutputStream().use { bytes ->
            DataOutputStream(bytes).use { output ->
                output.writeInt(1)
                output.writeUTF(snapshot.configDir)
                output.writeUTF(snapshot.configPath)
                output.writeInt(snapshot.apiPort)
                output.writeUTF(snapshot.apiSecret)
                output.writeBoolean(snapshot.selectedNodeName != null)
                snapshot.selectedNodeName?.let(output::writeUTF)
            }
            bytes.toByteArray()
        }
}
