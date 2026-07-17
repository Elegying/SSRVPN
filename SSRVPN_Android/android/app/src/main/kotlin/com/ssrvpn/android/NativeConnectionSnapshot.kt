package com.ssrvpn.android

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream

internal data class NativeConnectionSnapshot(
    val configDir: String,
    val configPath: String,
    val apiPort: Int,
    val apiSecret: String,
    val selectedNodeName: String?
)

internal object NativeConnectionSnapshotCodec {
    private const val VERSION = 1

    fun encode(snapshot: NativeConnectionSnapshot): ByteArray =
        ByteArrayOutputStream().use { bytes ->
            DataOutputStream(bytes).use { output ->
                output.writeInt(VERSION)
                output.writeUTF(snapshot.configDir)
                output.writeUTF(snapshot.configPath)
                output.writeInt(snapshot.apiPort)
                output.writeUTF(snapshot.apiSecret)
                output.writeBoolean(snapshot.selectedNodeName != null)
                snapshot.selectedNodeName?.let(output::writeUTF)
            }
            bytes.toByteArray()
        }

    fun decode(bytes: ByteArray): NativeConnectionSnapshot? = try {
        DataInputStream(ByteArrayInputStream(bytes)).use { input ->
            if (input.readInt() != VERSION) return null
            val snapshot = NativeConnectionSnapshot(
                configDir = input.readUTF(),
                configPath = input.readUTF(),
                apiPort = input.readInt(),
                apiSecret = input.readUTF(),
                selectedNodeName = if (input.readBoolean()) input.readUTF() else null
            )
            snapshot.takeIf {
                it.configDir.isNotBlank() &&
                    it.configPath.isNotBlank() &&
                    it.apiPort in 1..65535 &&
                    it.apiSecret.isNotBlank()
            }
        }
    } catch (_: Exception) {
        null
    }
}
