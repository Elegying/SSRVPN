package com.ssrvpn.android

import java.net.URI

/** Restricts MethodChannel-driven external navigation to ordinary web links. */
internal object ExternalUrlPolicy {
    fun normalizedHttpUrl(rawUrl: String?): String? {
        val candidate = rawUrl?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val uri = try {
            URI(candidate)
        } catch (_: Exception) {
            return null
        }
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        if (uri.host.isNullOrBlank() || uri.rawUserInfo != null) return null
        return uri.toASCIIString()
    }
}
