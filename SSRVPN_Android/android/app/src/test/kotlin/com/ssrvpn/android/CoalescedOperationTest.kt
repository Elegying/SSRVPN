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

        assertTrue(operation.joinOrBegin { completed += "first:$it" })
        assertFalse(operation.joinOrBegin { completed += "second:$it" })
        assertTrue(operation.isRunning)
        assertTrue(completed.isEmpty())

        operation.complete(true)

        assertFalse(operation.isRunning)
        assertEquals(listOf("first:true", "second:true"), completed)
    }

    @Test
    fun `a completed operation allows a new owner`() {
        val operation = CoalescedOperation()

        assertTrue(operation.joinOrBegin())
        operation.complete(false)

        assertTrue(operation.joinOrBegin())
    }
}
