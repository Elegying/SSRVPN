package com.ssrvpn.android

import java.lang.ref.WeakReference

/** Main-thread only. Retains the runtime, never a destroyed window. */
internal class RetainedUiSession<E : Any, H : Any> {
    private var runtime: E? = null
    private var host = WeakReference<H>(null)
    var hasPendingAction = false
        private set

    fun acquire(create: () -> E): E = runtime ?: create().also { runtime = it }

    fun attach(value: H) { host = WeakReference(value) }
    fun currentHost(): H? = host.get()
    fun enqueueAction() { hasPendingAction = true }
    fun consumeAction(): Boolean {
        if (host.get() == null) return false
        val pending = hasPendingAction
        hasPendingAction = false
        return pending
    }

    fun detach(value: H): Boolean {
        if (host.get() !== value) return false
        host.clear()
        return true
    }
}
