package com.ssrvpn.android

import java.net.NetworkInterface

internal data class NativeRuntimeDiagnostics(
    val serviceRunning: Boolean,
    val operationBusy: Boolean,
    val tunEstablished: Boolean?,
    val bridgeReady: Boolean?,
    val protectMonitorAlive: Boolean?
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "schemaVersion" to 1,
        "serviceRunning" to serviceRunning,
        "operationBusy" to operationBusy,
        "tunEstablished" to tunEstablished,
        "bridgeReady" to bridgeReady,
        "protectMonitorAlive" to protectMonitorAlive
    )
}

internal class NativeRuntimeDiagnosticsTracker {
    private data class TunOwnershipClaim(
        val descriptor: Long,
        val interfaceNames: Set<String>?
    )

    @Volatile
    private var tunOwnershipClaim: TunOwnershipClaim? = null

    fun claimTunDescriptor(
        descriptor: Long,
        activeTunInterfaces: () -> Set<String>? = ::activeTunInterfaceNames
    ) {
        tunOwnershipClaim = descriptor
            .takeIf { it in 1..Int.MAX_VALUE.toLong() }
            ?.let { TunOwnershipClaim(it, activeTunInterfaces()) }
    }

    fun releaseTunDescriptor() {
        tunOwnershipClaim = null
    }

    fun snapshot(
        serviceRunning: Boolean,
        operationBusy: Boolean,
        protectMonitorAlive: Boolean,
        bridgeReady: Boolean?,
        activeTunInterfaces: () -> Set<String>? = ::activeTunInterfaceNames
    ): NativeRuntimeDiagnostics {
        val claim = tunOwnershipClaim
        val currentTunInterfaces = activeTunInterfaces()
        val tunEstablished = when {
            claim == null -> false
            claim.interfaceNames == null || currentTunInterfaces == null -> null
            else -> claim.interfaceNames.any(currentTunInterfaces::contains)
        }
        return NativeRuntimeDiagnostics(
            serviceRunning = serviceRunning,
            operationBusy = operationBusy,
            tunEstablished = tunEstablished,
            bridgeReady = bridgeReady,
            protectMonitorAlive = protectMonitorAlive
        )
    }

    private companion object {
        fun activeTunInterfaceNames(): Set<String>? {
            return try {
                val interfaces = NetworkInterface.getNetworkInterfaces() ?: return null
                val active = mutableSetOf<String>()
                while (interfaces.hasMoreElements()) {
                    val network = interfaces.nextElement()
                    if (network.isUp && network.name.startsWith("tun")) {
                        active += network.name
                    }
                }
                active
            } catch (_: Exception) {
                null
            }
        }
    }
}
