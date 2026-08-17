package com.ssrvpn.android

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper

internal data class UnderlyingNetworkSnapshot(
    val available: Boolean,
    val validated: Boolean
)

internal class UnderlyingNetworkStateTracker<T> {
    private val networks = linkedMapOf<T, Boolean>()

    @Synchronized
    fun update(network: T, validated: Boolean) {
        networks[network] = validated
    }

    @Synchronized
    fun remove(network: T) {
        networks.remove(network)
    }

    @Synchronized
    fun snapshot(): UnderlyingNetworkSnapshot = UnderlyingNetworkSnapshot(
        available = networks.isNotEmpty(),
        validated = networks.values.any { it }
    )
}

/** Observes only physical/non-VPN internet networks used beneath SSRVPN. */
internal class UnderlyingNetworkMonitor(
    context: Context,
    private val onChanged: (UnderlyingNetworkSnapshot) -> Unit
) {
    private val connectivityManager =
        context.getSystemService(ConnectivityManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val tracker = UnderlyingNetworkStateTracker<Network>()
    private var started = false

    @Volatile
    private var publishedSnapshot: UnderlyingNetworkSnapshot? = null

    private val publishUnavailable = Runnable {
        publish(tracker.snapshot())
    }

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = refresh(network)

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities
        ) = refresh(network, networkCapabilities)

        override fun onLost(network: Network) {
            tracker.remove(network)
            schedulePublication()
        }
    }

    fun start() {
        if (started) return
        started = true
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        connectivityManager.registerNetworkCallback(request, callback)
        schedulePublication()
    }

    fun stop() {
        if (!started) return
        started = false
        handler.removeCallbacks(publishUnavailable)
        try {
            connectivityManager.unregisterNetworkCallback(callback)
        } catch (_: IllegalArgumentException) {
            // Already unregistered by the platform.
        }
    }

    fun snapshot(): UnderlyingNetworkSnapshot? = publishedSnapshot

    fun statusText(): String? = publishedSnapshot?.let {
        when {
            !it.available -> "无可用网络，VPN 正在等待恢复"
            !it.validated -> "网络尚未验证，VPN 正在等待恢复"
            else -> null
        }
    }

    private fun refresh(network: Network) {
        refresh(network, connectivityManager.getNetworkCapabilities(network))
    }

    private fun refresh(network: Network, capabilities: NetworkCapabilities?) {
        val isUnderlyingInternet = capabilities?.hasCapability(
            NetworkCapabilities.NET_CAPABILITY_INTERNET
        ) == true && capabilities.hasCapability(
            NetworkCapabilities.NET_CAPABILITY_NOT_VPN
        )
        if (isUnderlyingInternet) {
            tracker.update(
                network,
                capabilities.hasCapability(
                    NetworkCapabilities.NET_CAPABILITY_VALIDATED
                )
            )
        } else {
            tracker.remove(network)
        }
        schedulePublication()
    }

    private fun schedulePublication() {
        handler.removeCallbacks(publishUnavailable)
        val snapshot = tracker.snapshot()
        if (snapshot.available) {
            publish(snapshot)
        } else {
            handler.postDelayed(publishUnavailable, NETWORK_LOSS_DEBOUNCE_MS)
        }
    }

    private fun publish(snapshot: UnderlyingNetworkSnapshot) {
        if (!started || publishedSnapshot == snapshot) return
        publishedSnapshot = snapshot
        onChanged(snapshot)
    }

    companion object {
        private const val NETWORK_LOSS_DEBOUNCE_MS = 2_500L
    }
}
