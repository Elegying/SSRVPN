package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoalescedOperationTest {
    @Test
    fun `joiners complete only after the shared operation finishes`() {
        val operation = CoalescedOperation()
        val completed = mutableListOf<String>()

        assertTrue(operation.joinOrBegin { completed += "first" })
        assertFalse(operation.joinOrBegin { completed += "second" })
        assertTrue(operation.isRunning)
        assertTrue(completed.isEmpty())

        operation.complete()

        assertFalse(operation.isRunning)
        assertEquals(listOf("first", "second"), completed)
    }

    @Test
    fun `a completed operation allows a new owner`() {
        val operation = CoalescedOperation()

        assertTrue(operation.joinOrBegin())
        operation.complete()

        assertTrue(operation.joinOrBegin())
    }
}
