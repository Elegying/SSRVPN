package com.ssrvpn.android

internal class NotificationUpdatePolicy(
    val initialRefreshDelayMillis: Long = 10_000L,
    val refreshIntervalMillis: Long = 60_000L
) {
    private var screenInteractive = true
    private var lastPublishedState: VpnNotificationState? = null

    @Synchronized
    fun onScreenStateChanged(interactive: Boolean) {
        screenInteractive = interactive
    }

    @Synchronized
    fun shouldScheduleTrafficRefresh(): Boolean = screenInteractive

    @Synchronized
    fun shouldPublish(state: VpnNotificationState): Boolean {
        if (state == lastPublishedState) return false
        lastPublishedState = state
        return true
    }

    @Synchronized
    fun publishIfChanged(
        state: VpnNotificationState,
        publish: () -> Unit
    ): Boolean {
        if (state == lastPublishedState) return false
        publish()
        lastPublishedState = state
        return true
    }

    @Synchronized
    fun markPublished(state: VpnNotificationState) {
        lastPublishedState = state
    }

    @Synchronized
    fun resetPublishedState() {
        lastPublishedState = null
    }

    fun bytesPerSecond(deltaBytes: Long, elapsedMillis: Long): Long {
        if (deltaBytes <= 0L || elapsedMillis <= 0L) return 0L
        return deltaBytes * 1_000L / elapsedMillis
    }
}
