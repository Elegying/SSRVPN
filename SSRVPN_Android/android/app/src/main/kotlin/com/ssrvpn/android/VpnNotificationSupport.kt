package com.ssrvpn.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import java.util.Locale

internal data class VpnNotificationState(
    val nodeName: String,
    val connected: Boolean,
    val statusText: String?,
    val uploadRate: Long,
    val downloadRate: Long,
    val sessionUpload: Long,
    val sessionDownload: Long,
    val connectionStartedAt: Long
)

internal object VpnNotificationSupport {
    fun createChannel(context: Context, channelId: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            channelId,
            "SSRVPN",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "VPN 连接状态"
            setShowBadge(false)
        }
        context.getSystemService(NotificationManager::class.java)
            .createNotificationChannel(channel)
    }

    fun buildStatusNotification(
        context: Context,
        channelId: String,
        disconnectAction: String,
        state: VpnNotificationState
    ): Notification {
        val builder = builder(context, channelId)
        val openPending = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val disconnectPending = PendingIntent.getBroadcast(
            context,
            1,
            Intent(disconnectAction).setPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val rateText = state.statusText ?: if (state.connected) {
            "↑ ${formatBytes(state.uploadRate)}/s  ↓ ${formatBytes(state.downloadRate)}/s"
        } else {
            "正在连接 VPN..."
        }
        val detailText = if (state.connected) {
            "$rateText\n上传 ${formatBytes(state.sessionUpload)}  下载 ${formatBytes(state.sessionDownload)}"
        } else {
            rateText
        }
        return builder
            .setContentTitle(state.nodeName)
            .setContentText(rateText)
            .setStyle(Notification.BigTextStyle().bigText(detailText))
            .setSmallIcon(R.drawable.ic_vpn_tile)
            .setContentIntent(openPending)
            .addAction(Notification.Action.Builder(null, "断开", disconnectPending).build())
            .setWhen(state.connectionStartedAt)
            .setShowWhen(true)
            .setColor(Color.rgb(71, 108, 255))
            .setTicker(state.statusText ?: if (state.connected) "VPN 已连接" else "VPN 正在连接")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
    }

    fun buildRecoveryFailureNotification(context: Context, channelId: String): Notification {
        val openPending = PendingIntent.getActivity(
            context,
            2,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return builder(context, channelId)
            .setContentTitle("SSRVPN 已断开")
            .setContentText(CoreRecoveryPolicy.failureMessage)
            .setStyle(Notification.BigTextStyle().bigText(CoreRecoveryPolicy.failureMessage))
            .setSmallIcon(R.drawable.ic_vpn_tile)
            .setContentIntent(openPending)
            .setColor(Color.rgb(220, 53, 69))
            .setCategory(Notification.CATEGORY_ERROR)
            .setAutoCancel(true)
            .setOngoing(false)
            .build()
    }

    private fun builder(context: Context, channelId: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

    fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val units = arrayOf("KB", "MB", "GB", "TB")
        var value = bytes.toDouble() / 1024.0
        var unitIndex = 0
        while (value >= 1024 && unitIndex < units.lastIndex) {
            value /= 1024.0
            unitIndex++
        }
        return if (value >= 100) {
            "${value.toInt()} ${units[unitIndex]}"
        } else {
            String.format(Locale.US, "%.1f %s", value, units[unitIndex])
        }
    }
}
