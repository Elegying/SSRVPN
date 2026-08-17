package com.ssrvpn.android

import android.system.Os
import android.system.ErrnoException
import android.system.OsConstants
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

    @Volatile
    private var tunInterfaceBaseline: Set<String>? = null

    fun beginTunLease(
        tunInterfaces: () -> Set<String>? = ::tunInterfaceNames
    ) {
        tunInterfaceBaseline = tunInterfaces()
    }

    fun claimTunDescriptor(
        descriptor: Long,
        activeTunInterfaces: () -> Set<String>? = ::tunInterfaceNames
    ) {
        val baseline = tunInterfaceBaseline
        val current = activeTunInterfaces()
        val ownedInterfaces = if (baseline != null && current != null) {
            (current - baseline).takeIf { it.isNotEmpty() }
        } else {
            current
        }
        tunOwnershipClaim = descriptor.takeIf { it in 1..Int.MAX_VALUE.toLong() }
            ?.let { TunOwnershipClaim(it, ownedInterfaces) }
        tunInterfaceBaseline = null
    }

    fun releaseTunDescriptorIfClosed(
        tunInterfaces: () -> Set<String>? = ::tunInterfaceNames,
        descriptorTarget: (Long) -> String? = ::descriptorTarget
    ): Boolean {
        val claim = tunOwnershipClaim
        if (claim == null) {
            tunInterfaceBaseline = null
            return true
        }
        val currentInterfaces = tunInterfaces() ?: return false
        val ownedInterfaces = claim.interfaceNames ?: return false
        if (ownedInterfaces.any(currentInterfaces::contains)) return false
        val target = descriptorTarget(claim.descriptor)
        if (target == UNKNOWN_DESCRIPTOR_TARGET ||
            target == "/dev/tun" ||
            target?.startsWith("/dev/tun") == true
        ) {
            return false
        }
        tunOwnershipClaim = null
        return true
    }

    fun snapshot(
        serviceRunning: Boolean,
        operationBusy: Boolean,
        protectMonitorAlive: Boolean,
        bridgeReady: Boolean?,
        activeTunInterfaces: () -> Set<String>? = ::tunInterfaceNames
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
        fun tunInterfaceNames(): Set<String>? {
            return try {
                val interfaces = NetworkInterface.getNetworkInterfaces() ?: return null
                val names = mutableSetOf<String>()
                while (interfaces.hasMoreElements()) {
                    val network = interfaces.nextElement()
                    if (network.name.startsWith("tun")) names += network.name
                }
                names
            } catch (_: Exception) {
                null
            }
        }

        private const val UNKNOWN_DESCRIPTOR_TARGET = "<unknown>"

        fun descriptorTarget(descriptor: Long): String? =
            try {
                Os.readlink("/proc/self/fd/$descriptor")
            } catch (error: ErrnoException) {
                if (error.errno == OsConstants.ENOENT ||
                    error.errno == OsConstants.EBADF
                ) null else UNKNOWN_DESCRIPTOR_TARGET
            } catch (_: Exception) {
                UNKNOWN_DESCRIPTOR_TARGET
            }
    }
}

internal object TunReleaseVerifier {
    private const val DEFAULT_ATTEMPTS = 21
    private const val DEFAULT_RETRY_DELAY_MILLIS = 100L

    fun waitUntilReleased(
        attempts: Int = DEFAULT_ATTEMPTS,
        retryDelayMillis: Long = DEFAULT_RETRY_DELAY_MILLIS,
        isReleased: () -> Boolean
    ): Boolean {
        repeat(attempts.coerceAtLeast(1)) { attempt ->
            if (isReleased()) return true
            if (attempt + 1 < attempts && retryDelayMillis > 0) {
                try {
                    Thread.sleep(retryDelayMillis)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return false
                }
            }
        }
        return false
    }

    fun releaseOwnedLeaseAndWait(
        bridgeStopped: Boolean,
        attempts: Int = DEFAULT_ATTEMPTS,
        retryDelayMillis: Long = DEFAULT_RETRY_DELAY_MILLIS,
        closeOwnedLease: () -> Unit,
        isReleased: () -> Boolean
    ): Boolean {
        closeOwnedLease()
        if (!bridgeStopped) return false
        return waitUntilReleased(attempts, retryDelayMillis, isReleased)
    }
}
