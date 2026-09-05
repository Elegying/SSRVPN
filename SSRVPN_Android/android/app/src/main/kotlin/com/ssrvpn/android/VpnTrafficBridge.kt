package com.ssrvpn.android

import android.os.SystemClock

internal object VpnTrafficBridge {
    fun snapshot(): Map<String, Long>? = SsrvpnVpnService.startGeneration.withCurrent { generation ->
        SsrvpnVpnService.instance?.takeIf { SsrvpnVpnService.isRunning }
            ?.trafficTracker?.currentSessionSnapshot()
            ?.toMethodChannelMap(generation, SystemClock.elapsedRealtime())
    }
}
