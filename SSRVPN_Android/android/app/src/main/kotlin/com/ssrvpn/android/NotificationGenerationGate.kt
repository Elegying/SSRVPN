package com.ssrvpn.android

import java.util.concurrent.atomic.AtomicLong

internal class NotificationGenerationGate {
    private val generation = AtomicLong(0)

    fun capture(): Long = generation.get()

    fun invalidate(): Long = generation.incrementAndGet()

    fun isCurrent(token: Long): Boolean = token == generation.get()
}
