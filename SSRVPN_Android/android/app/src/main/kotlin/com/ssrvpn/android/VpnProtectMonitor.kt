package com.ssrvpn.android

import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileInputStream

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
                            when (val count = input.read(buffer)) {
                                4 -> {
                                    val socketFd = decodeLittleEndianInt(buffer)
                                    val protected = protectSocket(socketFd)
                                    Log.d(TAG, "protect($socketFd) = $protected")
                                    reportResult(protected)
                                }
                                -1 -> {
                                    Log.d(TAG, "Protect pipe closed")
                                    return@Thread
                                }
                                else -> Log.w(TAG, "Ignoring partial protect request: $count bytes")
                            }
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

    private fun decodeLittleEndianInt(buffer: ByteArray): Int =
        (buffer[0].toInt() and 0xFF) or
            ((buffer[1].toInt() and 0xFF) shl 8) or
            ((buffer[2].toInt() and 0xFF) shl 16) or
            ((buffer[3].toInt() and 0xFF) shl 24)
}
