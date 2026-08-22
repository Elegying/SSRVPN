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
        while (System.nanoTime() < deadlineNanos) {
            ensureCurrent()
            val readiness = probe(apiPort, apiSecret, deadlineNanos)
            ensureCurrent()
            if (readiness != MihomoApiReadiness.PENDING) return readiness

            val remainingNanos = (deadlineNanos - System.nanoTime()).coerceAtLeast(0L)
            if (remainingNanos == 0L) break
            Thread.sleep(
                minOf(
                    pollIntervalMillis.coerceAtLeast(1L),
                    TimeUnit.NANOSECONDS.toMillis(remainingNanos).coerceAtLeast(1L)
                )
            )
        }
        return MihomoApiReadiness.TIMEOUT
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
    MihomoApiReadiness.PENDING,
    MihomoApiReadiness.TIMEOUT -> MihomoApiStartupFailure(
        message = "VPN 核心已启动，但本地控制服务未及时就绪，请重新连接",
        category = NativeCoreStartFailureCategory.TIMEOUT
    )
    MihomoApiReadiness.READY -> error("Ready API does not have a startup failure")
}
