package com.ssrvpn.android

import android.system.Os
import android.system.ErrnoException
import android.system.OsConstants
import java.io.File
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

internal data class TunReleaseEvidence(
    val ownedInterfaceActive: Boolean?,
    val descriptorTargetsTun: Boolean?,
    val descriptorAttachedToOwnedInterface: Boolean?
)

internal data class TunDescriptorInterface(
    val readable: Boolean,
    val name: String?
)

internal class NativeRuntimeDiagnosticsTracker {
    private data class TunOwnershipClaim(
        val descriptor: Long,
        val baselineInterfaceNames: Set<String>?,
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
            current - baseline
        } else {
            current
        }
        tunOwnershipClaim = descriptor.takeIf { it in 1..Int.MAX_VALUE.toLong() }
            ?.let { TunOwnershipClaim(it, baseline, ownedInterfaces) }
        tunInterfaceBaseline = null
    }

    fun releaseTunDescriptorIfClosed(
        tunInterfaces: () -> Set<String>? = ::activeTunInterfaceNames,
        descriptorTarget: (Long) -> String? = ::descriptorTarget,
        descriptorInterface: (Long) -> TunDescriptorInterface = ::descriptorInterface
    ): Boolean {
        val claim = tunOwnershipClaim
        if (claim == null) {
            tunInterfaceBaseline = null
            return true
        }
        val currentInterfaces = tunInterfaces() ?: return false
        val ownedInterfaces = resolveOwnedTunInterfaces(claim, currentInterfaces)
            ?: return false
        if (ownedInterfaces.any(currentInterfaces::contains)) return false
        val target = descriptorTarget(claim.descriptor)
        if (target == UNKNOWN_DESCRIPTOR_TARGET ||
            target == "/dev/tun" || target?.startsWith("/dev/tun") == true
        ) {
            if (target == UNKNOWN_DESCRIPTOR_TARGET) return false
            val currentDescriptorInterface = descriptorInterface(claim.descriptor)
            if (!currentDescriptorInterface.readable) return false
            val interfaceName = currentDescriptorInterface.name
            if (interfaceName != null &&
                descriptorBelongsToClaim(claim, interfaceName) != false
            ) return false
        }
        if (tunOwnershipClaim !== claim) return false
        tunOwnershipClaim = null
        return true
    }

    fun tunReleaseEvidence(
        tunInterfaces: () -> Set<String>? = ::activeTunInterfaceNames,
        descriptorTarget: (Long) -> String? = ::descriptorTarget,
        descriptorInterface: (Long) -> TunDescriptorInterface = ::descriptorInterface
    ): TunReleaseEvidence {
        val claim = tunOwnershipClaim
            ?: return TunReleaseEvidence(false, false, false)
        val currentInterfaces = tunInterfaces()
        val ownedInterfaceActive = currentInterfaces?.let { current ->
            resolveOwnedTunInterfaces(claim, current)?.any(current::contains)
        }
        val target = descriptorTarget(claim.descriptor)
        val descriptorTargetsTun = when {
            target == UNKNOWN_DESCRIPTOR_TARGET -> null
            target == null -> false
            else -> target == "/dev/tun" || target.startsWith("/dev/tun")
        }
        val descriptorAttachedToOwnedInterface = when (descriptorTargetsTun) {
            null -> null
            false -> false
            true -> {
                val currentDescriptorInterface = descriptorInterface(claim.descriptor)
                if (!currentDescriptorInterface.readable) null else {
                    currentDescriptorInterface.name?.let {
                        descriptorBelongsToClaim(claim, it)
                    } ?: false
                }
            }
        }
        return TunReleaseEvidence(
            ownedInterfaceActive,
            descriptorTargetsTun,
            descriptorAttachedToOwnedInterface
        )
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
            currentTunInterfaces == null -> null
            else -> resolveOwnedTunInterfaces(claim, currentTunInterfaces)
                ?.any(currentTunInterfaces::contains)
        }
        return NativeRuntimeDiagnostics(
            serviceRunning = serviceRunning,
            operationBusy = operationBusy,
            tunEstablished = tunEstablished,
            bridgeReady = bridgeReady,
            protectMonitorAlive = protectMonitorAlive
        )
    }

    private fun resolveOwnedTunInterfaces(
        claim: TunOwnershipClaim,
        currentInterfaces: Set<String>
    ): Set<String>? {
        val knownInterfaces = claim.interfaceNames ?: return null
        val baselineInterfaces = claim.baselineInterfaceNames
            ?: return knownInterfaces.takeIf { it.isNotEmpty() }
        val resolvedInterfaces = knownInterfaces + (currentInterfaces - baselineInterfaces)
        if (resolvedInterfaces != knownInterfaces && tunOwnershipClaim === claim) {
            tunOwnershipClaim = claim.copy(interfaceNames = resolvedInterfaces)
        }
        return resolvedInterfaces
    }

    private fun descriptorBelongsToClaim(
        claim: TunOwnershipClaim,
        interfaceName: String
    ): Boolean? {
        val knownInterfaces = claim.interfaceNames ?: return null
        if (interfaceName in knownInterfaces) return true
        val baselineInterfaces = claim.baselineInterfaceNames ?: return null
        return interfaceName !in baselineInterfaces
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

        fun activeTunInterfaceNames(): Set<String>? {
            return try {
                val interfaces = NetworkInterface.getNetworkInterfaces() ?: return null
                val names = mutableSetOf<String>()
                while (interfaces.hasMoreElements()) {
                    val network = interfaces.nextElement()
                    if (network.isUp && network.name.startsWith("tun")) {
                        names += network.name
                    }
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

        fun descriptorInterface(descriptor: Long): TunDescriptorInterface =
            try {
                val interfaceName = File("/proc/self/fdinfo/$descriptor").useLines { lines ->
                    lines.take(32)
                        .firstOrNull { it.startsWith("iff:") }
                        ?.substringAfter(':')
                        ?.trim()
                        ?.takeIf(String::isNotEmpty)
                }
                TunDescriptorInterface(readable = true, name = interfaceName)
            } catch (_: Exception) {
                TunDescriptorInterface(readable = false, name = null)
            }
    }
}

internal object TunReleaseVerifier {
    // Android 11 can keep a closed TUN visible beyond the previous six-second grace.
    private const val DEFAULT_ATTEMPTS = 101
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
