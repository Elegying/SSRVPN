package com.ssrvpn.android

import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

internal object VpnStartResultRegistry {
    private const val TAG = "VpnStartResultRegistry"
    private val callbacks =
        ConcurrentHashMap<String, (Boolean, String, Map<String, Any?>?) -> Unit>()

    fun register(callback: (Boolean, String, Map<String, Any?>?) -> Unit): String {
        val requestId = UUID.randomUUID().toString()
        callbacks[requestId] = callback
        return requestId
    }

    fun clear(requestId: String?) {
        if (requestId != null) callbacks.remove(requestId)
    }

    fun consume(
        requestId: String?,
        success: Boolean,
        message: String,
        state: Map<String, Any?>? = null
    ) {
        val callback = requestId?.let(callbacks::remove) ?: return
        AndroidRuntimeGuard.run(TAG, "VPN start result callback failed") {
            callback(success, message, state)
        }
    }
}
