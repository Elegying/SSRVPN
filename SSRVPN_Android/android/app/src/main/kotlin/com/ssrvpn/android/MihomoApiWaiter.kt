package com.ssrvpn.android

import java.util.concurrent.TimeUnit

internal class MihomoApiWaiter(
    private val probe: (Int, String, Long) -> MihomoApiReadiness =
        MihomoApiHealthProbe::readiness
) {
    fun waitUntilReady(
        apiPort: Int,
        apiSecret: String,
        deadlineNanos: Long,
        pollIntervalMillis: Long,
        ensureCurrent: () -> Unit
    ): MihomoApiReadiness {
        var lastPending = MihomoApiReadiness.PENDING
        while (System.nanoTime() < deadlineNanos) {
            ensureCurrent()
            val readiness = probe(apiPort, apiSecret, deadlineNanos)
            ensureCurrent()
            if (readiness != MihomoApiReadiness.PENDING &&
                readiness != MihomoApiReadiness.RULES_PENDING) return readiness
            lastPending = readiness

            val remainingNanos = (deadlineNanos - System.nanoTime()).coerceAtLeast(0L)
            if (remainingNanos == 0L) break
            Thread.sleep(
                minOf(
                    pollIntervalMillis.coerceAtLeast(1L),
                    TimeUnit.NANOSECONDS.toMillis(remainingNanos).coerceAtLeast(1L)
                )
            )
        }
        return if (lastPending == MihomoApiReadiness.RULES_PENDING) lastPending else MihomoApiReadiness.TIMEOUT
    }
}

internal data class MihomoApiStartupFailure(
    val message: String,
    val category: NativeCoreStartFailureCategory
)

internal fun MihomoApiReadiness.startupFailure(): MihomoApiStartupFailure = when (this) {
    MihomoApiReadiness.PORT_CONFLICT -> MihomoApiStartupFailure(
        message = "本地控制端口已被其他应用占用，请重试，SSRVPN 将自动更换端口",
        category = NativeCoreStartFailureCategory.PORT_CONFLICT
    )
    MihomoApiReadiness.AUTH_REJECTED -> MihomoApiStartupFailure(
        message = "本地控制凭据不可用或与运行配置不一致，请重启应用后重试",
        category = NativeCoreStartFailureCategory.API_AUTH
    )
    MihomoApiReadiness.TUN_DISABLED -> MihomoApiStartupFailure(
        message = "VPN 核心未能启用 TUN 网络接口，请重新连接",
        category = NativeCoreStartFailureCategory.TUN
    )
    MihomoApiReadiness.RULES_PENDING -> MihomoApiStartupFailure(
        message = "分流规则尚未就绪",
        category = NativeCoreStartFailureCategory.RULES
    )
    MihomoApiReadiness.PENDING,
    MihomoApiReadiness.TIMEOUT -> MihomoApiStartupFailure(
        message = "VPN 核心已启动，但本地控制服务未及时就绪，请重新连接",
        category = NativeCoreStartFailureCategory.TIMEOUT
    )
    MihomoApiReadiness.READY -> error("Ready API does not have a startup failure")
}

/** Prepares services without a VPN lease; the caller retains capture ownership. */
internal fun prepareMihomoForVpn(
    apiPort: Int, apiSecret: String, deadlineNanos: Long,
    prepareBridge: () -> String?, ensureCurrent: () -> Unit, selectNode: () -> Unit,
    waiter: MihomoApiWaiter = MihomoApiWaiter(MihomoApiHealthProbe::preparationReadiness)
): MihomoApiStartupFailure? {
    ensureCurrent()
    val error = prepareBridge()
    ensureCurrent()
    if (error == null || error.isNotEmpty()) return MihomoApiStartupFailure(
        "连接服务准备失败，请重新连接",
        if (error == null) NativeCoreStartFailureCategory.TIMEOUT else NativeCoreStartFailureCategory.COMPONENT)
    val ready = waiter.waitUntilReady(apiPort, apiSecret, deadlineNanos,
        VpnStartBudget.API_POLL_MS, ensureCurrent)
    if (ready != MihomoApiReadiness.READY) return ready.startupFailure()
    ensureCurrent()
    selectNode()
    ensureCurrent()
    requireVpnStartupBudget(deadlineNanos)
    return null
}

internal fun requireVpnStartupBudget(deadlineNanos: Long) {
    if (System.nanoTime() >= deadlineNanos) throw java.util.concurrent.TimeoutException("VPN startup deadline")
}
