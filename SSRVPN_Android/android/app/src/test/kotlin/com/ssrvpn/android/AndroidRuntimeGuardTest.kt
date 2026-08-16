package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class AndroidRuntimeGuardTest {
    @Test
    fun `recoverable Android runtime exception is contained and reported`() {
        val failure = IllegalStateException("system service unavailable")
        var reported: Exception? = null

        val completed = AndroidRuntimeGuard.run(
            tag = "test",
            message = "platform operation failed",
            onFailure = { reported = it }
        ) {
            throw failure
        }

        assertFalse(completed)
        assertSame(failure, reported)
    }

    @Test
    fun `fatal VM errors are not swallowed`() {
        assertThrows(AssertionError::class.java) {
            AndroidRuntimeGuard.run("test", "fatal") {
                throw AssertionError("fatal")
            }
        }
    }
}
