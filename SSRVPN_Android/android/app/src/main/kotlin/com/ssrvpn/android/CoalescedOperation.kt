package com.ssrvpn.android

/** Lets duplicate callers await one shared operation instead of racing it. */
internal class CoalescedOperation {
    private val lock = Any()
    private var running = false
    private val completions = mutableListOf<() -> Unit>()

    val isRunning: Boolean
        get() = synchronized(lock) { running }

    fun joinOrBegin(onComplete: (() -> Unit)? = null): Boolean = synchronized(lock) {
        if (onComplete != null) completions += onComplete
        if (running) return@synchronized false
        running = true
        true
    }

    fun complete() {
        val pending = synchronized(lock) {
            running = false
            completions.toList().also { completions.clear() }
        }
        pending.forEach { runCatching(it) }
    }
}
