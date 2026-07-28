package com.ssrvpn.android

import android.content.Context
import android.content.SharedPreferences
import java.util.UUID

internal interface AutoConnectCapabilityStore {
    fun read(): Map<String, Long>
    fun replace(entries: Map<String, Long>): Boolean
}

private class SharedPreferencesAutoConnectCapabilityStore(context: Context) :
    AutoConnectCapabilityStore {
    private val preferences: SharedPreferences = context.getSharedPreferences(
        AutoConnectRequestRegistry.STORAGE_NAME,
        Context.MODE_PRIVATE
    )

    override fun read(): Map<String, Long> =
        preferences.all.mapNotNull { (requestId, issuedAt) ->
            (issuedAt as? Long)?.let { requestId to it }
        }.toMap()

    override fun replace(entries: Map<String, Long>): Boolean {
        val editor = preferences.edit().clear()
        entries.forEach { (requestId, issuedAt) -> editor.putLong(requestId, issuedAt) }
        return editor.commit()
    }
}

/**
 * Short-lived, one-shot capabilities issued only by the trusted quick tile.
 *
 * MainActivity is exported as the launcher activity, so a public boolean extra
 * cannot authorize a VPN state change. Capabilities are synchronously persisted
 * in app-private storage so the tile-to-activity handoff survives process death.
 */
internal object AutoConnectRequestRegistry {
    const val EXTRA_REQUEST_ID = "com.ssrvpn.android.AUTO_CONNECT_REQUEST_ID"
    internal const val STORAGE_NAME = "ssrvpn_auto_connect_capabilities"
    internal const val REQUEST_TTL_MS = 60_000L
    private const val MAX_PENDING_REQUESTS = 16

    fun issue(context: Context): String? = issue(
        SharedPreferencesAutoConnectCapabilityStore(context),
        System.currentTimeMillis(),
        UUID.randomUUID().toString()
    )

    fun consume(context: Context, requestId: String?): Boolean = consume(
        SharedPreferencesAutoConnectCapabilityStore(context),
        requestId,
        System.currentTimeMillis()
    )

    @Synchronized
    internal fun issue(
        store: AutoConnectCapabilityStore,
        nowMillis: Long,
        requestId: String
    ): String? {
        require(isCanonicalUuid(requestId)) { "Auto-connect request id must be a UUID" }
        val pending = activeEntries(store.read(), nowMillis).toMutableMap()
        while (pending.size >= MAX_PENDING_REQUESTS) {
            val oldest = pending.entries.minWithOrNull(
                compareBy<Map.Entry<String, Long>> { it.value }.thenBy { it.key }
            ) ?: break
            pending.remove(oldest.key)
        }
        pending[requestId] = nowMillis
        return requestId.takeIf { store.replace(pending) }
    }

    @Synchronized
    internal fun consume(
        store: AutoConnectCapabilityStore,
        requestId: String?,
        nowMillis: Long
    ): Boolean {
        if (requestId == null || !isCanonicalUuid(requestId)) return false
        val stored = store.read()
        val pending = activeEntries(stored, nowMillis).toMutableMap()
        if (pending.remove(requestId) == null) {
            if (pending != stored) store.replace(pending)
            return false
        }
        return store.replace(pending)
    }

    private fun activeEntries(entries: Map<String, Long>, nowMillis: Long): Map<String, Long> =
        entries.filter { (requestId, issuedAt) ->
            val age = nowMillis - issuedAt
            isCanonicalUuid(requestId) &&
                issuedAt <= nowMillis &&
                age >= 0L &&
                age < REQUEST_TTL_MS
        }

    private fun isCanonicalUuid(value: String): Boolean =
        value.length == 36 && try {
            UUID.fromString(value).toString() == value
        } catch (_: IllegalArgumentException) {
            false
        }
}
