package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class DetachedTunFdOwnerTest {
    @Test
    fun `cancellation before bridge transfer closes the descriptor once`() {
        val closes = AtomicInteger(0)
        val owner = DetachedTunFdOwner(42) { descriptor ->
            assertEquals(42, descriptor)
            closes.incrementAndGet()
        }

        owner.close()
        owner.close()

        assertEquals(1, closes.get())
        assertThrows(IllegalStateException::class.java) {
            owner.startWithBridge({}, {}) { "" }
        }
    }

    @Test
    fun `successful bridge start commits ownership without closing the descriptor`() {
        val closes = AtomicInteger(0)
        val terminationRequests = AtomicInteger(0)
        val owner = DetachedTunFdOwner(43) { closes.incrementAndGet() }

        val result = owner.startWithBridge(
            prepareBridge = {},
            requireProcessTermination = { terminationRequests.incrementAndGet() }
        ) { descriptor ->
            assertEquals(43L, descriptor)
            ""
        }
        owner.close()

        assertEquals("", result)
        assertEquals(0, closes.get())
        assertEquals(0, terminationRequests.get())
    }

    @Test
    fun `only proven pre-adoption bridge errors close the descriptor`() {
        val earlyErrors = listOf(
            "already running",
            "read config: missing config.yaml",
            "parse config: invalid field"
        )

        earlyErrors.forEachIndexed { index, bridgeError ->
            val closes = AtomicInteger(0)
            val terminationRequests = AtomicInteger(0)
            val owner = DetachedTunFdOwner(45 + index) { closes.incrementAndGet() }

            val result = owner.startWithBridge(
                prepareBridge = {},
                requireProcessTermination = { terminationRequests.incrementAndGet() }
            ) { bridgeError }
            owner.close()

            assertEquals(bridgeError, result)
            assertEquals(1, closes.get())
            assertEquals(0, terminationRequests.get())
        }
    }

    @Test
    fun `panic unknown and near-match errors require process termination without raw close`() {
        val ambiguousErrors = listOf(
            "panic: applyRoute failed",
            "unknown bridge error",
            "read config:",
            "parse config:",
            "already running "
        )

        ambiguousErrors.forEachIndexed { index, bridgeError ->
            val closes = AtomicInteger(0)
            val terminationRequests = AtomicInteger(0)
            val owner = DetachedTunFdOwner(50 + index) { closes.incrementAndGet() }

            val result = owner.startWithBridge(
                prepareBridge = {},
                requireProcessTermination = { terminationRequests.incrementAndGet() }
            ) { bridgeError }
            owner.close()

            assertEquals(bridgeError, result)
            assertEquals(0, closes.get())
            assertEquals(1, terminationRequests.get())
        }
    }

    @Test
    fun `bridge exception requires process termination without raw close`() {
        val closes = AtomicInteger(0)
        val terminationRequests = AtomicInteger(0)
        val owner = DetachedTunFdOwner(60) { closes.incrementAndGet() }

        assertThrows(IllegalStateException::class.java) {
            owner.startWithBridge(
                prepareBridge = {},
                requireProcessTermination = { terminationRequests.incrementAndGet() }
            ) {
                throw IllegalStateException("JNI failure")
            }
        }
        owner.close()

        assertEquals(0, closes.get())
        assertEquals(1, terminationRequests.get())
    }

    @Test
    fun `bridge error is normalized and requires termination without raw close`() {
        val closes = AtomicInteger(0)
        val terminationRequests = AtomicInteger(0)
        val owner = DetachedTunFdOwner(62) { closes.incrementAndGet() }
        val bridgeError = AssertionError("JNI error")

        val thrown = assertThrows(Exception::class.java) {
            owner.startWithBridge(
                prepareBridge = {},
                requireProcessTermination = { terminationRequests.incrementAndGet() }
            ) {
                throw bridgeError
            }
        }
        owner.close()

        assertEquals(bridgeError, thrown.cause)
        assertEquals(0, closes.get())
        assertEquals(1, terminationRequests.get())
    }

    @Test
    fun `termination callback failure is not caught and invoked twice`() {
        val closes = AtomicInteger(0)
        val terminationRequests = AtomicInteger(0)
        val owner = DetachedTunFdOwner(63) { closes.incrementAndGet() }

        assertThrows(IllegalStateException::class.java) {
            owner.startWithBridge(
                prepareBridge = {},
                requireProcessTermination = {
                    terminationRequests.incrementAndGet()
                    throw IllegalStateException("termination handoff failed")
                }
            ) { "panic: bridge failed" }
        }
        owner.close()

        assertEquals(0, closes.get())
        assertEquals(1, terminationRequests.get())
    }

    @Test
    fun `prepare exception leaves descriptor safely owned by Kotlin`() {
        val closes = AtomicInteger(0)
        val terminationRequests = AtomicInteger(0)
        val owner = DetachedTunFdOwner(61) { closes.incrementAndGet() }

        assertThrows(IllegalArgumentException::class.java) {
            owner.startWithBridge(
                prepareBridge = { throw IllegalArgumentException("init failed") },
                requireProcessTermination = { terminationRequests.incrementAndGet() }
            ) { "" }
        }
        owner.close()

        assertEquals(1, closes.get())
        assertEquals(0, terminationRequests.get())
    }

    @Test
    fun `cancellation during bridge start defers close until failure is known`() {
        val closes = AtomicInteger(0)
        val owner = DetachedTunFdOwner(46) { closes.incrementAndGet() }

        owner.startWithBridge({}, {}) {
            assertEquals(46L, it)
            owner.close()
            assertEquals(0, closes.get())
            "read config: cancelled"
        }

        assertEquals(1, closes.get())
    }

    @Test
    fun `cancellation during successful bridge start leaves the descriptor with bridge`() {
        val closes = AtomicInteger(0)
        val owner = DetachedTunFdOwner(47) { closes.incrementAndGet() }

        owner.startWithBridge({}, {}) {
            assertEquals(47L, it)
            owner.close()
            ""
        }

        assertEquals(0, closes.get())
    }

    @Test
    fun `concurrent cancellation and bridge transfer choose one owner`() {
        repeat(100) {
            val closes = AtomicInteger(0)
            val transfers = AtomicInteger(0)
            val owner = DetachedTunFdOwner(44) { closes.incrementAndGet() }
            val start = CountDownLatch(1)
            val pool = Executors.newFixedThreadPool(2)
            try {
                val transfer = pool.submit {
                    start.await()
                    try {
                        owner.startWithBridge({}, {}) { "" }
                        transfers.incrementAndGet()
                    } catch (_: IllegalStateException) {
                        // Cancellation won ownership.
                    }
                }
                val cancel = pool.submit {
                    start.await()
                    owner.close()
                }
                start.countDown()
                transfer.get(1, TimeUnit.SECONDS)
                cancel.get(1, TimeUnit.SECONDS)
            } finally {
                pool.shutdownNow()
            }

            assertEquals(1, closes.get() + transfers.get())
        }
    }
}
