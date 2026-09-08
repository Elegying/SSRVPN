package com.ssrvpn.android

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Keep DNS and the probe socket on the same physical network, even during VPN. */
internal object PhysicalTcpLatencyProbe {
    private val workers = ThreadPoolExecutor(
        0, 16, 30, TimeUnit.SECONDS, SynchronousQueue(),
        { task -> Thread(task, "SSRVPN-physical-latency").apply { isDaemon = true } }
    )
    private val handler by lazy { Handler(Looper.getMainLooper()) }

    fun register(
        context: Context,
        messenger: BinaryMessenger,
        deliver: (() -> Unit) -> Unit
    ) {
        val manager = context.applicationContext.getSystemService(ConnectivityManager::class.java)
        MethodChannel(messenger, "com.ssrvpn/physical_latency").setMethodCallHandler { call, result ->
            if (call.method != "probe") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val host = call.argument<String>("server") ?: ""
            val port = call.argument<Int>("port") ?: 0
            val timeout = call.argument<Int>("timeoutMs") ?: 0
            if (!validArguments(host, port, timeout)) {
                result.success(-1)
                return@setMethodCallHandler
            }
            val start = SystemClock.elapsedRealtime()
            val settled = AtomicBoolean(false)
            val socket = AtomicReference<Socket?>(null)
            fun finish(value: Int) {
                if (!settled.compareAndSet(false, true)) return
                try { socket.getAndSet(null)?.close() } catch (_: Exception) { }
                deliver { result.success(value) }
            }
            val deadline = Runnable { finish(-1) }
            handler.postDelayed(deadline, timeout.toLong())
            try {
                workers.execute {
                    var value = -1
                    try {
                        val network = chooseNetwork(manager)
                        if (network != null) {
                            // Network.getAllByName uses this network's resolver/cache;
                            // never resolve through the process-default VPN DNS.
                            val addresses = network.getAllByName(host).filter(::usableAddress)
                            for (address in addresses) {
                                val remaining = timeout - (SystemClock.elapsedRealtime() - start)
                                if (settled.get() || remaining <= 0 || !physical(manager, network)) break
                                val connection = network.socketFactory.createSocket()
                                socket.set(connection)
                                try {
                                    if (settled.get()) break
                                    connection.connect(InetSocketAddress(address, port), remaining.toInt())
                                    val elapsed = SystemClock.elapsedRealtime() - start
                                    if (!settled.get() && elapsed < timeout && physical(manager, network)) {
                                        value = elapsed.coerceAtLeast(1).toInt()
                                    }
                                    break
                                } catch (_: Exception) {
                                    // Try another address within the same total deadline.
                                } finally {
                                    socket.compareAndSet(connection, null)
                                    try { connection.close() } catch (_: Exception) { }
                                }
                            }
                        }
                    } catch (_: Exception) {
                        // No network or denied binding is a failed probe, never a fallback.
                    } finally {
                        finish(value)
                        handler.removeCallbacks(deadline)
                    }
                }
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                handler.removeCallbacks(deadline)
                finish(-1)
            }
        }
    }

    internal fun validArguments(host: String, port: Int, timeout: Int): Boolean =
        host.isNotEmpty() && host.length <= 253 && host.none { it.isWhitespace() || it == '\u0000' } &&
            port in 1..65535 && timeout in 1..60000

    internal fun usableAddress(address: InetAddress): Boolean {
        if (address !is Inet4Address || address.isAnyLocalAddress ||
            address.isLoopbackAddress || address.isLinkLocalAddress || address.isMulticastAddress) return false
        val bytes = address.address.map { it.toInt() and 255 }
        return bytes[0] != 0 && !(bytes[0] == 198 && bytes[1] in 18..19) && bytes[0] < 224
    }

    private fun physical(manager: ConnectivityManager, network: Network): Boolean {
        val caps = manager.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    @Suppress("DEPRECATION")
    private fun chooseNetwork(manager: ConnectivityManager): Network? {
        val active = manager.activeNetwork
        if (active != null && physical(manager, active)) return active
        return manager.allNetworks.filter { physical(manager, it) }.sortedByDescending {
            manager.getNetworkCapabilities(it)?.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_VALIDATED
            ) == true
        }.firstOrNull()
    }
}
