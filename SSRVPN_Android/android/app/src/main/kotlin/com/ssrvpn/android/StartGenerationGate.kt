package com.ssrvpn.android

internal class StartGenerationGate {
    private val lock = Any()
    private var generation = 0L

    fun beginStart(onStarted: () -> Unit = {}): Long = synchronized(lock) {
        generation += 1
        onStarted()
        generation
    }

    fun invalidate(onInvalidated: () -> Unit = {}): Long = synchronized(lock) {
        generation += 1
        onInvalidated()
        generation
    }

    fun current(): Long = synchronized(lock) { generation }

    fun <T> withCurrent(action: (Long) -> T): T = synchronized(lock) {
        action(generation)
    }

    fun runIfCurrent(token: Long, action: () -> Unit): Boolean = synchronized(lock) {
        if (token != generation) return false
        action()
        true
    }
}
