package com.ssrvpn.android

/** Lets duplicate callers await one shared operation instead of racing it. */
internal class CoalescedOperation {
    private val lock = Any()
    private var running = false
    private val completions = mutableListOf<(Boolean) -> Unit>()

    val isRunning: Boolean
        get() = synchronized(lock) { running }

    fun joinOrBegin(onComplete: ((Boolean) -> Unit)? = null): Boolean = synchronized(lock) {
        if (onComplete != null) completions += onComplete
        if (running) return@synchronized false
        running = true
        true
    }

    fun complete(stoppedCleanly: Boolean) {
        val pending = synchronized(lock) {
            running = false
            completions.toList().also { completions.clear() }
        }
        pending.forEach { completion -> runCatching { completion(stoppedCleanly) } }
    }
}
