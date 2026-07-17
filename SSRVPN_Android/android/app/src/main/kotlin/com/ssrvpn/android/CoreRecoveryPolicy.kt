package com.ssrvpn.android

internal data class CoreRecoveryRequest(
    val configDir: String,
    val configPath: String,
    val apiPort: Int,
    val apiSecret: String,
    val selectedNodeName: String?,
    val attempt: Int
)

internal object CoreRecoveryPolicy {
    private const val MAX_ATTEMPTS = 1

    fun nextAttempt(currentAttempt: Int): Int? =
        (currentAttempt + 1).takeIf { it <= MAX_ATTEMPTS }

    fun recoveringMessage(attempt: Int): String =
        "核心异常，正在自动恢复（$attempt/$MAX_ATTEMPTS）"

    fun shouldAcceptRestart(
        attempt: Int,
        intentToken: Long?,
        currentToken: Long,
        manualStopRequested: Boolean
    ): Boolean =
        attempt > 0 &&
            intentToken != null &&
            intentToken == currentToken &&
            !manualStopRequested

    fun shouldPublishRecovery(
        recoveryToken: Long,
        currentToken: Long,
        manualStopRequested: Boolean,
        processTerminationPending: Boolean
    ): Boolean =
        recoveryToken == currentToken &&
            !manualStopRequested &&
            !processTerminationPending

    const val failureMessage = "核心异常，自动恢复失败，请重新连接"
}
