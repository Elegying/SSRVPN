package com.ssrvpn.android

import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileInputStream
import java.io.InputStream

internal object VpnProtectMonitor {
    private const val TAG = "VpnProtectMonitor"

    fun start(
        protectReadFd: Long,
        protectSocket: (Int) -> Boolean,
        reportResult: (Boolean) -> Unit
    ): Thread? {
        if (protectReadFd <= 0L) return null

        return Thread({
            try {
                ParcelFileDescriptor.fromFd(protectReadFd.toInt()).use { descriptor ->
                    FileInputStream(descriptor.fileDescriptor).use { input ->
                        val buffer = ByteArray(4)
                        while (!Thread.currentThread().isInterrupted) {
                            val socketFd = readSocketFd(input) ?: run {
                                Log.d(TAG, "Protect pipe closed")
                                return@Thread
                            }
                            val protected = protectSocket(socketFd)
                            Log.d(TAG, "protect($socketFd) = $protected")
                            reportResult(protected)
                        }
                    }
                }
            } catch (error: Exception) {
                Log.e(TAG, "Protect monitor failed", error)
            }
        }, "SSRVPN-protect").apply {
            isDaemon = true
            start()
        }
    }

    internal fun readSocketFd(input: InputStream): Int? {
        val buffer = ByteArray(4)
        var offset = 0
        while (offset < buffer.size) {
            val count = input.read(buffer, offset, buffer.size - offset)
            if (count == -1) return null
            if (count == 0) continue
            offset += count
        }
        return decodeLittleEndianInt(buffer)
    }

    private fun decodeLittleEndianInt(buffer: ByteArray): Int =
        (buffer[0].toInt() and 0xFF) or
            ((buffer[1].toInt() and 0xFF) shl 8) or
            ((buffer[2].toInt() and 0xFF) shl 16) or
            ((buffer[3].toInt() and 0xFF) shl 24)
}
