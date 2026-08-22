package com.ssrvpn.android

import android.util.Log

internal object AndroidRuntimeGuard {
    fun run(
        tag: String,
        message: String,
        onFailure: ((Exception) -> Unit)? = null,
        operation: () -> Unit
    ): Boolean = try {
        operation()
        true
    } catch (error: Exception) {
        try {
            onFailure?.invoke(error) ?: run {
                val category = NativeCoreStartFailureCategory.from(error).logValue
                Log.e(tag, "$message cause=$category")
            }
        } catch (_: Exception) {
            // Error reporting is best-effort inside this process-safety boundary.
        }
        false
    }
}
