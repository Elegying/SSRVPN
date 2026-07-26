package com.ssrvpn.android

import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Keeps one foreground-start payload in process memory while the Intent carries
 * only an opaque identifier. Payloads are consumed at most once.
 */
internal object NativeStartPayloadRegistry {
    private val payloads = ConcurrentHashMap<String, NativeConnectionSnapshot>()

    fun register(snapshot: NativeConnectionSnapshot): String =
        UUID.randomUUID().toString().also { payloads[it] = snapshot }

    fun peek(id: String?): NativeConnectionSnapshot? =
        id?.let(payloads::get)

    fun consume(id: String?): NativeConnectionSnapshot? =
        id?.let(payloads::remove)

    fun discard(id: String?) {
        if (id != null) payloads.remove(id)
    }
}
