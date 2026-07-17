package com.ssrvpn.android

internal class NotificationUpdatePolicy(
    val initialRefreshDelayMillis: Long = 10_000L,
    val refreshIntervalMillis: Long = 60_000L
) {
    private var screenInteractive = true
    private var lastPublishedState: VpnNotificationState? = null

    fun onScreenStateChanged(interactive: Boolean) {
        screenInteractive = interactive
    }

    fun shouldScheduleTrafficRefresh(): Boolean = screenInteractive

    fun shouldPublish(state: VpnNotificationState): Boolean {
        if (state == lastPublishedState) return false
        lastPublishedState = state
        return true
    }

    fun markPublished(state: VpnNotificationState) {
        lastPublishedState = state
    }

    fun resetPublishedState() {
        lastPublishedState = null
    }

    fun bytesPerSecond(deltaBytes: Long, elapsedMillis: Long): Long {
        if (deltaBytes <= 0L || elapsedMillis <= 0L) return 0L
        return deltaBytes * 1_000L / elapsedMillis
    }
}
