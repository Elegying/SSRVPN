package com.ssrvpn.android

import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.InputStream

internal object VpnProtectMonitor {
    private const val TAG = "VpnProtectMonitor"

    internal class Monitor(
        val thread: Thread,
        private val input: InputStream
    ) {
        fun stop() {
            try {
                input.close()
            } catch (_: Exception) {}
            thread.interrupt()
        }
    }

    fun start(
        protectReadFd: Long,
        protectSocket: (Int) -> Boolean,
        reportResult: (Boolean) -> Unit
    ): Monitor? {
        if (protectReadFd <= 0L) return null
        // Bridge retains the raw descriptor until Bridge.stop(). Read from a
        // duplicate so native cleanup cannot invalidate Java's monitor mid-run.
        val input = ParcelFileDescriptor.AutoCloseInputStream(
            ParcelFileDescriptor.fromFd(protectReadFd.toInt())
        )
        return start(input, protectSocket, reportResult)
    }

    internal fun start(
        input: InputStream,
        protectSocket: (Int) -> Boolean,
        reportResult: (Boolean) -> Unit
    ): Monitor {
        val thread = Thread({
            try {
                input.use {
                    while (!Thread.currentThread().isInterrupted) {
                        val socketFd = readSocketFd(it) ?: run {
                            Log.d(TAG, "Protect pipe closed")
                            return@Thread
                        }
                        val protected = protectSocket(socketFd)
                        Log.d(TAG, "protect($socketFd) = $protected")
                        if (!reportResultSafely(protected, reportResult)) {
                            Log.e(TAG, "Native protect result reporter is unavailable")
                            return@Thread
                        }
                    }
                }
            } catch (error: LinkageError) {
                Log.e(TAG, "Protect monitor native linkage failed", error)
            } catch (error: Exception) {
                Log.e(TAG, "Protect monitor failed", error)
            }
        }, "SSRVPN-protect").apply {
            isDaemon = true
            start()
        }
        return Monitor(thread, input)
    }

    internal fun reportResultSafely(
        protected: Boolean,
        reportResult: (Boolean) -> Unit
    ): Boolean = try {
        reportResult(protected)
        true
    } catch (_: LinkageError) {
        false
    } catch (_: Exception) {
        false
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
