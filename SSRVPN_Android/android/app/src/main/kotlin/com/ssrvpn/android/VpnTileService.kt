package com.ssrvpn.android

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 快速设置磁贴 — 下拉通知栏 VPN 开关
 * 支持：App 内同步状态 / App 未运行时直接连接
 */
class VpnTileService : TileService() {
    companion object {
        private const val TAG = "VpnTile"
        const val ACTION_VPN_STATE_CHANGED = "com.ssrvpn.VPN_STATE_CHANGED"
        const val EXTRA_CONNECTED = "connected"
    }

    private var isConnected = false
    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_VPN_STATE_CHANGED) {
                isConnected = intent.getBooleanExtra(EXTRA_CONNECTED, false)
                Log.d(TAG, "State changed: connected=$isConnected")
                updateTile()
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        val filter = IntentFilter(ACTION_VPN_STATE_CHANGED)
        ContextCompat.registerReceiver(
            this,
            stateReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        isConnected = SsrvpnVpnService.isRunning
        updateTile()
        Log.d(TAG, "onStartListening: connected=$isConnected")
    }

    override fun onStopListening() {
        super.onStopListening()
        try { unregisterReceiver(stateReceiver) } catch (_: Exception) {}
    }

    override fun onClick() {
        super.onClick()
        Log.d(TAG, "onClick: current=$isConnected")

        if (isConnected) {
            stopVpnAndUpdateTile(cancelPendingStart = false)
        } else {
            startVpnDirectly()
        }
    }

    /** 从磁贴拉起 App（Android 14+ 必须用 startActivityAndCollapse + PendingIntent） */
    private fun launchApp() {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("AUTO_CONNECT", true)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pending = PendingIntent.getActivity(
                this, 2, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(launchIntent)
        }
    }

    /** 直接启动 VPN 服务（不依赖 Flutter） */
    private fun startVpnDirectly() {
        if (SsrvpnVpnService.isCoreOperationBusy()) {
            Log.d(TAG, "Cancelling VPN operation from tile")
            stopVpnAndUpdateTile(cancelPendingStart = true)
            return
        }
        // 检查 VPN 权限
        val vpnIntent = VpnService.prepare(this)
        if (vpnIntent != null) {
            // 需要用户授权，打开 App
            Log.d(TAG, "Need VPN permission, opening app")
            launchApp()
            return
        }

        // Snapshot read and start reservation share the native generation lock.
        // A concurrent cleanup therefore either wins before this read (and the
        // snapshot is absent) or observes the reservation and defers deletion.
        val claim = NativeVpnSessionCoordinator.claimSnapshotForStart(this)
        if (claim == null) {
            launchApp()
            return
        }
        val snapshot = claim.snapshot

        // 已有权限，直接启动
        Log.d(TAG, "Starting VPN directly from tile")
        val consumed = AtomicBoolean(false)
        lateinit var callback: (Boolean, String, Map<String, Any?>?) -> Unit
        callback = { success, message, _ ->
            if (consumed.compareAndSet(false, true)) {
                NativeVpnSessionCoordinator.releasePendingStart(claim.id)
                Log.d(TAG, "VPN start result: $success, $message")
                isConnected = success
                updateTile()
                notifyStateChanged()
            }
        }
        val requestId = VpnStartResultRegistry.register(callback)
        val intent = SsrvpnVpnService.createStartIntent(
            this,
            snapshot.configDir,
            snapshot.configPath,
            snapshot.apiPort,
            snapshot.apiSecret,
            snapshot.selectedNodeName,
            requestId,
            claim.id
        )
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (error: Exception) {
            NativeVpnSessionCoordinator.releasePendingStart(claim.id)
            VpnStartResultRegistry.clear(requestId)
            consumed.set(true)
            Log.e(TAG, "Unable to start VPN service from tile", error)
            launchApp()
            return
        }
        // 30 秒超时清理回调，防止泄漏
        android.os.Handler(mainLooper).postDelayed({
            if (consumed.compareAndSet(false, true)) {
                Log.w(TAG, "VPN start callback timeout, clearing")
                NativeVpnSessionCoordinator.releasePendingStart(claim.id)
                VpnStartResultRegistry.clear(requestId)
            }
        }, 30_000L)
        // 不再提前设置 isConnected = true，等回调确认后再更新磁贴状态
    }

    private fun stopVpnAndUpdateTile(cancelPendingStart: Boolean) {
        if (cancelPendingStart) SsrvpnVpnService.cancelPendingStart()
        val service = SsrvpnVpnService.instance
        if (service == null) {
            stopService(Intent(this, SsrvpnVpnService::class.java))
            isConnected = SsrvpnVpnService.isRunning
            updateTile()
            notifyStateChanged()
            return
        }
        service.stopAll {
            android.os.Handler(mainLooper).post {
                isConnected = SsrvpnVpnService.isRunning
                updateTile()
                notifyStateChanged()
            }
        }
    }

    private fun notifyStateChanged() {
        sendBroadcast(Intent(ACTION_VPN_STATE_CHANGED).apply {
            putExtra(EXTRA_CONNECTED, isConnected)
            // Android 14+ 隐式广播不会投递给 NOT_EXPORTED 接收器，必须显式指定包名
            setPackage(packageName)
        })
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        if (isConnected) {
            tile.state = Tile.STATE_ACTIVE
            tile.label = "已连接"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                tile.stateDescription = "SSRVPN"
            }
        } else {
            tile.state = Tile.STATE_INACTIVE
            tile.label = "SSRVPN"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                tile.stateDescription = "点击连接"
            }
        }
        tile.updateTile()
    }
}
