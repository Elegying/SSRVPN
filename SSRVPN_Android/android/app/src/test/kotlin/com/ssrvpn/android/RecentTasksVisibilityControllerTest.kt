package com.ssrvpn.android

import org.junit.Assert.*
import org.junit.Test

class RecentTasksVisibilityControllerTest {
    private class Task(var flag: Boolean = false) : RecentTasksVisibilityController.Task {
        override val excluded: Boolean get() = flag
        val changes = mutableListOf<Boolean>()
        var failure: ((Boolean) -> Unit)? = null
        override fun setExcluded(value: Boolean) {
            changes += value
            flag = value
            failure?.invoke(value)
        }
    }

    private class Fixture {
        var saved = false
        val first = Task()
        val second = Task()
        var listed = listOf(first, second)
        val writes = mutableListOf<Boolean>()
        var writeFailure: ((Boolean) -> Unit)? = null
        fun controller() = RecentTasksVisibilityController(
            { saved },
            {
                writes += it
                saved = it // SharedPreferences changes its memory cache even if commit fails.
                writeFailure?.invoke(it)
            },
            { listed }
        )
    }

    @Test fun `default remains visible without writing`() {
        val f = Fixture()
        assertFalse(f.controller().restore())
        assertTrue(f.first.changes.isEmpty())
        assertTrue(f.writes.isEmpty())
    }

    @Test fun `toggle applies to all main tasks and persists both directions`() {
        val f = Fixture()
        assertTrue(f.controller().setEnabled(true))
        assertTrue(f.first.excluded && f.second.excluded && f.saved)
        assertFalse(f.controller().setEnabled(false))
        assertFalse(f.first.excluded || f.second.excluded || f.saved)
        assertEquals(listOf(true, false), f.writes)
    }

    @Test fun `cold restart and new task restore the saved choice`() {
        val f = Fixture()
        f.controller().setEnabled(true)
        val reopened = Task()
        f.listed = listOf(reopened)
        assertTrue(f.controller().restore())
        assertTrue(reopened.excluded)
        assertEquals(listOf(true), f.writes)
    }

    @Test fun `repeated requests are idempotent but reconcile changed task flags`() {
        val f = Fixture()
        val controller = f.controller()
        controller.setEnabled(true)
        controller.setEnabled(true)
        assertEquals(listOf(true), f.first.changes)
        f.first.flag = false
        controller.setEnabled(true)
        assertTrue(f.first.excluded)
        assertEquals(listOf(true), f.writes)
    }

    @Test fun `platform failure rolls back even the task that threw after mutation`() {
        val f = Fixture()
        f.second.failure = { if (it) throw SecurityException("denied") }
        assertThrows(SecurityException::class.java) { f.controller().setEnabled(true) }
        assertFalse(f.first.excluded || f.second.excluded || f.saved)
        assertTrue(f.writes.isEmpty())
    }

    @Test fun `failed persistence restores tasks and preference memory`() {
        val f = Fixture()
        f.writeFailure = { if (it) throw IllegalStateException("disk full") }
        assertThrows(IllegalStateException::class.java) { f.controller().setEnabled(true) }
        assertFalse(f.first.excluded || f.second.excluded || f.saved)
        assertEquals(listOf(true, false), f.writes)
    }

    @Test fun `failed disabling retains the enabled preference and task exclusion`() {
        val f = Fixture()
        f.controller().setEnabled(true)
        f.writeFailure = { if (!it) throw IllegalStateException("disk full") }
        assertThrows(IllegalStateException::class.java) { f.controller().setEnabled(false) }
        assertTrue(f.first.excluded && f.second.excluded && f.saved)
    }

    @Test fun `rollback failure cannot turn an unsuccessful operation into success`() {
        val f = Fixture()
        f.second.failure = { throw IllegalStateException("task vanished") }
        val error = assertThrows(IllegalStateException::class.java) {
            f.controller().setEnabled(true)
        }
        assertEquals(1, error.suppressed.size)
        assertFalse(f.first.excluded)
        assertFalse(f.saved)
    }

    @Test fun `missing task fails without saving`() {
        val f = Fixture()
        f.listed = emptyList()
        assertThrows(IllegalStateException::class.java) { f.controller().setEnabled(true) }
        assertTrue(f.writes.isEmpty())
    }

    @Test fun `read failure prevents every side effect`() {
        var writes = 0
        var lists = 0
        val controller = RecentTasksVisibilityController(
            { throw IllegalStateException("unreadable preference") },
            { writes++ },
            { lists++; emptyList() }
        )
        assertThrows(IllegalStateException::class.java) { controller.setEnabled(true) }
        assertEquals(0, writes)
        assertEquals(0, lists)
    }

    @Test fun `saved choice survives failed lifecycle reconciliation and can retry`() {
        val f = Fixture()
        f.saved = true
        f.second.failure = { if (it) throw IllegalStateException("temporary failure") }
        assertThrows(IllegalStateException::class.java) { f.controller().restore() }
        assertTrue(f.saved)
        assertFalse(f.first.excluded || f.second.excluded)
        f.second.failure = null
        assertTrue(f.controller().restore())
        assertTrue(f.first.excluded && f.second.excluded)
        assertTrue(f.writes.isEmpty())
    }
}
