package com.ssrvpn.android

internal data class CoreRecoveryRequest(
    val configDir: String,
    val configPath: String,
    val apiPort: Int,
    val apiSecret: String,
    val attempt: Int
)

internal class CoreRecoveryBudget(
    initialAttempt: Int,
    private val stableHealthMillis: Long = 120_000L
) {
    var attempt: Int = initialAttempt
        private set
    private var healthySinceMillis: Long? = null

    fun observeHealth(isHealthy: Boolean?, monotonicMillis: Long) {
        if (attempt == 0) return
        if (isHealthy != true) {
            healthySinceMillis = null
            return
        }
        val healthySince = healthySinceMillis
        if (healthySince == null) {
            healthySinceMillis = monotonicMillis
            return
        }
        if (monotonicMillis - healthySince >= stableHealthMillis) attempt = 0
    }
}

internal object CoreRecoveryPolicy {
    private const val MAX_ATTEMPTS = 2
    private const val START_FAILURE_RETRY_DELAY_MILLIS = 1_000L

    fun nextAttempt(currentAttempt: Int): Int? =
        (currentAttempt + 1).takeIf { it <= MAX_ATTEMPTS }

    /**
     * A normal user start has no silent retry. The first automatic recovery
     * start may fail transiently while native resources are still settling,
     * so it receives exactly one delayed final attempt.
     */
    fun retryAfterStartFailure(currentAttempt: Int): Int? =
        if (currentAttempt > 0) nextAttempt(currentAttempt) else null

    fun retryDelayMillis(attempt: Int): Long =
        if (attempt in 1..MAX_ATTEMPTS) START_FAILURE_RETRY_DELAY_MILLIS else 0L

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
