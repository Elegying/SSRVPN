package com.ssrvpn.android

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.FutureTask
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** A timed-out JNI call retains its lease until the actual call returns. */
internal class BridgeRunningProbe {
    private val inProgress = AtomicBoolean(false)
    private val worker = ThreadPoolExecutor(
        1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1)
    ) { task -> Thread(task, "SSRVPN-bridge-is-running").apply { isDaemon = true } }

    fun check(timeoutMillis: Long, readRunning: () -> Boolean): Boolean? {
        if (!inProgress.compareAndSet(false, true)) return null
        val result = FutureTask<Boolean> {
            try {
                readRunning()
            } finally {
                inProgress.set(false)
            }
        }
        try {
            worker.execute(result)
        } catch (error: Throwable) {
            inProgress.set(false)
            throw error
        }
        try {
            return result.get(timeoutMillis, TimeUnit.MILLISECONDS)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw error
        }
    }
}
