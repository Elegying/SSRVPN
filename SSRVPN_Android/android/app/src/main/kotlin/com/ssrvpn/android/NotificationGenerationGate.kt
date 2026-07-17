package com.ssrvpn.android

import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicLong

internal class NotificationGenerationGate {
    private val generation = AtomicLong(0)

    fun capture(): Long = generation.get()

    fun invalidate(): Long = generation.incrementAndGet()

    fun isCurrent(token: Long): Boolean = token == generation.get()

    fun <T> publishLatest(
        handler: Handler,
        value: T,
        isRunning: () -> Boolean,
        allowPublication: (() -> Boolean)? = null,
        token: Long = capture(),
        publish: (T) -> Unit
    ) {
        if (Looper.myLooper() != handler.looper) {
            handler.post {
                publishLatest(handler, value, isRunning, allowPublication, token, publish)
            }
            return
        }
        val allowed = allowPublication?.invoke() ?: (isCurrent(token) && isRunning())
        if (allowed) publish(value)
    }
}
