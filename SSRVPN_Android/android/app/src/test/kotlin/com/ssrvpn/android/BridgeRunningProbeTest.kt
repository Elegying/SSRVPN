package com.ssrvpn.android

import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class BridgeRunningProbeTest {
    @Test
    fun `successful checks reuse the same daemon worker`() {
        val probe = BridgeRunningProbe()
        var firstWorker: Thread? = null
        assertEquals(true, probe.check(1_000) {
            firstWorker = Thread.currentThread()
            true
        })
        repeat(20) {
            assertEquals(false, probe.check(1_000) {
                assertSame(firstWorker, Thread.currentThread())
                assertTrue(Thread.currentThread().isDaemon)
                false
            })
        }
    }

    @Test
    fun `failed JNI check releases its lease without replacing the worker`() {
        val probe = BridgeRunningProbe()
        var failedWorker: Thread? = null
        val failure = assertThrows(ExecutionException::class.java) {
            probe.check(1_000) {
                failedWorker = Thread.currentThread()
                throw LinkageError("test unavailable bridge")
            }
        }
        assertTrue(failure.cause is LinkageError)
        assertEquals(true, probe.check(1_000) {
            assertSame(failedWorker, Thread.currentThread())
            true
        })
    }

    @Test
    fun `timeout does not cancel a blocked JNI call or queue later checks`() {
        val probe = BridgeRunningProbe()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val actualCalls = AtomicInteger()
        try {
            assertThrows(TimeoutException::class.java) {
                probe.check(20) {
                    actualCalls.incrementAndGet()
                    entered.countDown()
                    try {
                        release.await()
                        true
                    } finally {
                        completed.countDown()
                    }
                }
            }
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            repeat(50) {
                assertNull(probe.check(20) {
                    actualCalls.incrementAndGet()
                    false
                })
            }
            assertEquals(1, actualCalls.get())
            assertEquals(1L, completed.count)
        } finally {
            release.countDown()
        }
        assertTrue(completed.await(1, TimeUnit.SECONDS))
        // A late true result must not be reused by the next session's check.
        awaitIdle(probe)
        assertEquals(false, probe.check(1_000) { false })
        assertEquals(1, actualCalls.get())
    }

    @Test
    fun `interrupted waiter retains interrupt status and the active JNI lease`() {
        val probe = BridgeRunningProbe()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val observedInterrupt = AtomicReference<Boolean>()
        val waiter = Thread {
            try {
                probe.check(5_000) {
                    entered.countDown()
                    release.await()
                    true
                }
            } catch (_: InterruptedException) {
                observedInterrupt.set(Thread.currentThread().isInterrupted)
            }
        }.apply { isDaemon = true; start() }
        try {
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            waiter.interrupt()
            waiter.join(1_000)
            assertFalse(waiter.isAlive)
            assertEquals(true, observedInterrupt.get())
            assertNull(probe.check(20) { error("must not queue another JNI call") })
        } finally {
            release.countDown()
        }
        awaitIdle(probe)
    }

    private fun awaitIdle(probe: BridgeRunningProbe) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(1)
        while (probe.check(1_000) { true } == null && System.nanoTime() < deadline) {
            Thread.yield()
        }
        assertEquals(true, probe.check(1_000) { true })
    }
}
