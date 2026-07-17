package com.ssrvpn.android

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StartGenerationGateTest {
    @Test
    fun `disconnect cannot be overwritten by an obsolete connected publication`() {
        val gate = StartGenerationGate()
        val token = gate.beginStart()
        val connected = AtomicBoolean(false)
        val publicationEntered = CountDownLatch(1)
        val allowPublication = CountDownLatch(1)

        val publisher = thread {
            gate.runIfCurrent(token) {
                publicationEntered.countDown()
                allowPublication.await(1, TimeUnit.SECONDS)
                connected.set(true)
            }
        }
        assertTrue(publicationEntered.await(1, TimeUnit.SECONDS))

        val stopper = thread {
            gate.invalidate { connected.set(false) }
        }
        allowPublication.countDown()
        publisher.join(1_000)
        stopper.join(1_000)

        assertFalse(connected.get())
        assertFalse(gate.runIfCurrent(token) { connected.set(true) })
    }
}
