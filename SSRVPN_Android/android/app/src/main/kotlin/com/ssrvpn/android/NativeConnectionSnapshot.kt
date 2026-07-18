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
    private const val LEGACY_VERSION = 1
    private const val VERSION = 2
    // Shared subscription validation permits 64 KiB UTF-16 strings. This
    // covers their worst-case UTF-8 representation while bounding allocations.
    private const val MAX_UTF8_FIELD_BYTES = 256 * 1024

    fun encode(snapshot: NativeConnectionSnapshot): ByteArray =
        ByteArrayOutputStream().use { bytes ->
            DataOutputStream(bytes).use { output ->
                output.writeInt(VERSION)
                writeUtf8(output, snapshot.configDir)
                writeUtf8(output, snapshot.configPath)
                output.writeInt(snapshot.apiPort)
                writeUtf8(output, snapshot.apiSecret)
                output.writeBoolean(snapshot.selectedNodeName != null)
                snapshot.selectedNodeName?.let { writeUtf8(output, it) }
            }
            bytes.toByteArray()
        }

    fun decode(bytes: ByteArray): NativeConnectionSnapshot? = try {
        DataInputStream(ByteArrayInputStream(bytes)).use { input ->
            val snapshot = when (input.readInt()) {
                LEGACY_VERSION -> readSnapshot(input) { it.readUTF() }
                VERSION -> readSnapshot(input, ::readUtf8)
                else -> return null
            }
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

    private fun readSnapshot(
        input: DataInputStream,
        readString: (DataInputStream) -> String
    ): NativeConnectionSnapshot = NativeConnectionSnapshot(
        configDir = readString(input),
        configPath = readString(input),
        apiPort = input.readInt(),
        apiSecret = readString(input),
        selectedNodeName = if (input.readBoolean()) readString(input) else null
    )

    private fun writeUtf8(output: DataOutputStream, value: String) {
        val encoded = value.toByteArray(Charsets.UTF_8)
        require(encoded.size <= MAX_UTF8_FIELD_BYTES) {
            "Native connection snapshot field is too large"
        }
        output.writeInt(encoded.size)
        output.write(encoded)
    }

    private fun readUtf8(input: DataInputStream): String {
        val length = input.readInt()
        require(length in 0..MAX_UTF8_FIELD_BYTES) {
            "Invalid native connection snapshot field length"
        }
        return ByteArray(length).also(input::readFully).toString(Charsets.UTF_8)
    }
}
