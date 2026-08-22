package com.ssrvpn.android

/** Bounded categories for native core startup logs and MethodChannel errors. */
internal enum class NativeCoreStartFailureCategory(
    val logValue: String,
    val methodChannelCode: String,
    private val matchPriority: Int
) {
    PERMISSION("permission", "CORE_START_PERMISSION", 0),
    PORT_CONFLICT("port_conflict", "CORE_START_PORT_CONFLICT", 1),
    API_AUTH("api_auth", "CORE_START_API_AUTH", 2),
    TUN("tun", "CORE_START_TUN", 3),
    CONFIG("config", "CORE_START_CONFIG", 4),
    TIMEOUT("timeout", "CORE_START_TIMEOUT", 5),
    COMPONENT("component", "CORE_START_COMPONENT", 6),
    BUSY("busy", "CORE_START_BUSY", 7),
    UNKNOWN("unknown", "CORE_START_UNKNOWN", 8);

    val methodChannelFailureState: Map<String, Any?>
        get() = mapOf(FAILURE_CODE_KEY to methodChannelCode)

    companion object {
        const val FAILURE_CODE_KEY = "failureCode"
        private const val MAX_CAUSE_DEPTH = 4

        fun methodChannelCodeFromState(state: Map<String, Any?>?): String {
            val capturedCode = state?.get(FAILURE_CODE_KEY) as? String
            return entries.firstOrNull { it.methodChannelCode == capturedCode }
                ?.methodChannelCode
                ?: UNKNOWN.methodChannelCode
        }

        fun from(raw: String): NativeCoreStartFailureCategory {
            val value = raw.take(2_048).lowercase()
            return when {
                value.contains("permission") || value.contains("denied") -> PERMISSION
                value.contains("address already in use") ||
                    value.contains("eaddrinuse") ||
                    value.contains("bindexception") ||
                    value.contains("only one usage of each socket address") ->
                    PORT_CONFLICT
                value.contains("unauthorized") ||
                    value.contains("api auth") ||
                    value.contains("controller credential") -> API_AUTH
                value.contains("tun") ||
                    value.contains("protect monitor") ||
                    value.contains("socket protect") -> TUN
                value.contains("config") || value.contains("yaml") -> CONFIG
                value.contains("timeout") || value.contains("timed out") -> TIMEOUT
                value.contains("linkageerror") ||
                    value.contains("unsatisfiedlinkerror") ||
                    value.contains("native component") -> COMPONENT
                value.contains("already in progress") ||
                    value.contains("already running") ||
                    value.contains("正在启动") ||
                    value.contains("正在清理") -> BUSY
                else -> UNKNOWN
            }
        }

        fun from(error: Throwable): NativeCoreStartFailureCategory {
            var current: Throwable? = error
            var bestMatch = UNKNOWN
            repeat(MAX_CAUSE_DEPTH) {
                val candidate = current ?: return bestMatch
                val category = when (candidate) {
                    is SecurityException -> PERMISSION
                    is java.net.BindException -> PORT_CONFLICT
                    is java.net.SocketTimeoutException,
                    is java.util.concurrent.TimeoutException -> TIMEOUT
                    else -> from(
                        "${candidate.javaClass.simpleName} ${candidate.message.orEmpty()}"
                    )
                }
                if (category.matchPriority < bestMatch.matchPriority) {
                    bestMatch = category
                }
                current = candidate.cause
            }
            return bestMatch
        }
    }
}

internal data class NativeCoreStartInputFailure(
    val category: NativeCoreStartFailureCategory,
    val message: String
)

internal fun nativeCoreStartInputFailure(
    configDir: String?,
    configPath: String?,
    apiSecret: String
): NativeCoreStartInputFailure? = when {
    configDir == null || configPath == null -> NativeCoreStartInputFailure(
        NativeCoreStartFailureCategory.CONFIG,
        "VPN 配置不可用，请打开应用重新连接"
    )
    apiSecret.isBlank() -> NativeCoreStartInputFailure(
        NativeCoreStartFailureCategory.API_AUTH,
        "VPN 凭据不可用，请打开应用重新连接"
    )
    else -> null
}
