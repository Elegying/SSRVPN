package com.ssrvpn.android

internal object CoreDataPorts {
    fun fromPreferences(values: Map<String, *>): List<Int> = listOf(
        validOrDefault(values["flutter.proxyPort"], 7890),
        validOrDefault(values["flutter.socksPort"], 7891),
    ).distinct()

    private fun validOrDefault(value: Any?, default: Int): Int =
        (value as? Number)?.toInt()?.takeIf { it in 1..65535 } ?: default
}
