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
            onFailure?.invoke(error) ?: Log.e(tag, message, error)
        } catch (_: Exception) {
            // Error reporting is best-effort inside this process-safety boundary.
        }
        false
    }
}
