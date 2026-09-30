package com.ssrvpn.android

/** Request-local monotonic timings; no paths, nodes, secrets or retained history. */
internal class NativeVpnStartTiming(private val nowNanos: () -> Long) {
    private val startedAt = nowNanos()
    private var permissionStartedAt: Long? = null
    private var permissionEndedAt: Long? = null
    private var serviceStartedAt: Long? = null

    @Synchronized
    fun beginPermissionWait() {
        if (permissionStartedAt == null) permissionStartedAt = nowNanos()
    }

    @Synchronized
    fun endPermissionWait() {
        if (permissionStartedAt != null && permissionEndedAt == null) {
            permissionEndedAt = nowNanos()
        }
    }

    @Synchronized
    fun beginServiceStart() {
        endPermissionWait()
        if (serviceStartedAt == null) serviceStartedAt = nowNanos()
    }

    @Synchronized
    fun snapshot(): Map<String, Any> {
        val now = nowNanos()
        fun milliseconds(start: Long, end: Long) =
            ((end - start).coerceAtLeast(0L) / 1_000_000L)
        return mapOf(
            "authorizationRequested" to (permissionStartedAt != null),
            "authorizationWaitMs" to (permissionStartedAt?.let {
                milliseconds(it, permissionEndedAt ?: now)
            } ?: 0L),
            "serviceStartMs" to (serviceStartedAt?.let {
                milliseconds(it, now)
            } ?: 0L),
            "totalMs" to milliseconds(startedAt, now)
        )
    }
}
