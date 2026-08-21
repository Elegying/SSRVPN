package com.ssrvpn.android

import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.Closeable
import java.util.concurrent.atomic.AtomicInteger

internal class BridgeStartThrowableException(cause: Throwable) :
    Exception("Bridge.start threw ${cause::class.java.simpleName}", cause)

internal fun Throwable.asBridgeStartException(): Exception =
    this as? Exception ?: BridgeStartThrowableException(this)

/**
 * Owns a raw descriptor after ParcelFileDescriptor.detachFd().
 *
 * Kotlin remains the cleanup owner until Bridge.start begins. A successful return
 * commits ownership to Bridge. Only errors proven to occur before native adoption
 * close the raw descriptor here; panic/unknown/throw paths require process
 * termination because the numeric fd may already have been closed and reused.
 */
internal class DetachedTunFdOwner(
    descriptor: Int,
    private val closeDescriptor: (Int) -> Unit
) : Closeable {
    init {
        require(descriptor > 0) { "TUN descriptor must be positive" }
    }

    private val rawDescriptor = descriptor
    private val ownershipState = AtomicInteger(KOTLIN_OWNED)
    val descriptorNumber: Long = descriptor.toLong()

    fun startWithBridge(
        prepareBridge: () -> Unit,
        requireProcessTermination: () -> Unit,
        startBridge: (Long) -> String
    ): String {
        prepareBridge()
        val descriptor = beginBridgeStart()
        val result = try {
            startBridge(descriptor)
        } catch (error: Throwable) {
            markOwnershipAmbiguous()
            requireProcessTermination()
            throw error.asBridgeStartException()
        }
        when {
            result.isEmpty() -> commitBridgeOwnership()
            isProvenPreAdoptionFailure(result) -> closeAfterKnownPreAdoptionFailure()
            else -> {
                markOwnershipAmbiguous()
                requireProcessTermination()
            }
        }
        return result
    }

    private fun beginBridgeStart(): Long {
        check(ownershipState.compareAndSet(KOTLIN_OWNED, BRIDGE_START_IN_FLIGHT)) {
            "TUN descriptor is no longer available for Bridge.start"
        }
        return descriptorNumber
    }

    private fun commitBridgeOwnership() {
        while (true) {
            when (val state = ownershipState.get()) {
                BRIDGE_START_IN_FLIGHT, CLOSE_PENDING -> {
                    if (ownershipState.compareAndSet(state, BRIDGE_OWNED)) return
                }
                else -> error("Bridge.start has no pending TUN ownership")
            }
        }
    }

    private fun closeAfterKnownPreAdoptionFailure() {
        while (true) {
            val state = ownershipState.get()
            if (state == CLOSED) return
            check(state == BRIDGE_START_IN_FLIGHT || state == CLOSE_PENDING) {
                "Bridge.start has no Kotlin-owned TUN descriptor to close"
            }
            if (ownershipState.compareAndSet(state, CLOSED)) {
                closeDescriptor(rawDescriptor)
                return
            }
        }
    }

    private fun markOwnershipAmbiguous() {
        while (true) {
            when (val state = ownershipState.get()) {
                BRIDGE_START_IN_FLIGHT, CLOSE_PENDING -> {
                    if (ownershipState.compareAndSet(state, TERMINATION_REQUIRED)) return
                }
                TERMINATION_REQUIRED -> return
                else -> error("Bridge.start has no ambiguous TUN ownership")
            }
        }
    }

    override fun close() {
        while (true) {
            when (val state = ownershipState.get()) {
                KOTLIN_OWNED -> {
                    if (ownershipState.compareAndSet(state, CLOSED)) {
                        closeDescriptor(rawDescriptor)
                        return
                    }
                }
                BRIDGE_START_IN_FLIGHT -> {
                    if (ownershipState.compareAndSet(state, CLOSE_PENDING)) return
                }
                CLOSE_PENDING, BRIDGE_OWNED, TERMINATION_REQUIRED, CLOSED -> return
            }
        }
    }

    companion object {
        private const val TAG = "DetachedTunFdOwner"
        private const val KOTLIN_OWNED = 0
        private const val BRIDGE_START_IN_FLIGHT = 1
        private const val CLOSE_PENDING = 2
        private const val BRIDGE_OWNED = 3
        private const val TERMINATION_REQUIRED = 4
        private const val CLOSED = 5

        private fun isProvenPreAdoptionFailure(result: String): Boolean =
            result == "already running" ||
                result.startsWith("read config: ") ||
                result.startsWith("parse config: ") ||
                result == "protect monitor is unavailable"

        fun detach(descriptor: ParcelFileDescriptor): DetachedTunFdOwner {
            val rawDescriptor = try {
                descriptor.detachFd()
            } finally {
                descriptor.close()
            }
            if (rawDescriptor <= 0) {
                if (rawDescriptor >= 0) closeAndroidDescriptor(rawDescriptor)
                throw IllegalStateException("Invalid VPN fd")
            }
            return DetachedTunFdOwner(rawDescriptor, ::closeAndroidDescriptor)
        }

        private fun closeAndroidDescriptor(rawDescriptor: Int) {
            try {
                ParcelFileDescriptor.adoptFd(rawDescriptor).close()
                Log.d(TAG, "Closed unclaimed TUN fd=$rawDescriptor")
            } catch (error: Exception) {
                Log.e(TAG, "Unable to close unclaimed TUN fd=$rawDescriptor", error)
            }
        }
    }
}
