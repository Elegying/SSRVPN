package com.ssrvpn.android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** One lazy UI runtime per process. The native VPN service does not create it. */
internal object SsrvpnFlutterRuntime {
    private val session = RetainedUiSession<FlutterEngine, MainActivity>()
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var channel: MethodChannel

    fun acquire(context: Context): FlutterEngine = session.acquire {
        val app = context.applicationContext
        FlutterEngine(app).also { engine ->
            val messenger = engine.dartExecutor.binaryMessenger
            channel = MethodChannel(messenger, "com.ssrvpn/native")
            channel.setMethodCallHandler { call, result ->
                val host = session.currentHost()
                if (host != null && !host.isFinishing && !host.isDestroyed) {
                    host.handleNativeMethodCall(call, result)
                } else {
                    handleDetachedCall(app, call, result)
                }
            }
            PhysicalTcpLatencyProbe.register(app, messenger) { action ->
                handler.post {
                    AndroidRuntimeGuard.run("FlutterRuntime", "Unable to deliver physical latency", operation = action)
                }
            }
            AndroidRuntimeGuard.run("FlutterRuntime", "Unable to register VPN state receiver") {
                ContextCompat.registerReceiver(app, object : BroadcastReceiver() {
                    override fun onReceive(context: Context?, intent: Intent?) {
                        if (intent?.action == VpnTileService.ACTION_VPN_STATE_CHANGED) syncState()
                    }
                }, IntentFilter(VpnTileService.ACTION_VPN_STATE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
            }
            Log.i("FlutterRuntime", "UI runtime created")
        }
    }

    fun attach(activity: MainActivity): MethodChannel {
        session.attach(activity)
        return channel
    }

    fun isHost(activity: MainActivity) = session.currentHost() === activity
    val hasPendingAutoConnect: Boolean get() = session.hasPendingAction
    fun enqueueAutoConnect() = session.enqueueAction()
    fun consumeAutoConnect(): Boolean = session.consumeAction()

    fun detach(activity: MainActivity): Boolean = session.detach(activity)

    fun syncState() {
        AndroidRuntimeGuard.run("FlutterRuntime", "Unable to deliver VPN state") {
            channel.invokeMethod("vpnStateChanged", SsrvpnVpnService.isRunning)
        }
    }

    private fun handleDetachedCall(app: Context, call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getNativeLibraryDir" -> result.success(app.applicationInfo.nativeLibraryDir)
                "getAppDataDir" -> result.success(app.applicationInfo.dataDir)
                "isCoreRunning" -> result.success(SsrvpnVpnService.isRunning)
                "getConnectionState" -> result.success(NativeVpnSessionCoordinator.connectionState())
                "getConnectionSnapshotGeneration" -> result.success(NativeConnectionSnapshotStore.generation(app))
                "getRuleRetentionConfigPaths" -> result.success(NativeVpnSessionCoordinator.ruleRetentionConfigPaths(app))
                "consumePendingAutoConnect" -> result.success(false)
                "notifyVpnStateChanged" -> { SsrvpnVpnService.broadcastState(app); result.success(true) }
                "stopCore" -> stopDetachedSession(app, call, result)
                // Window-dependent actions must fail explicitly, never queue a new
                // connection or replay an installer/permission request on re-entry.
                else -> result.error("UI_UNAVAILABLE", "请返回应用后重试", null)
            }
        } catch (_: Exception) {
            result.error("NATIVE_STATE_UNAVAILABLE", "暂时无法读取连接状态", null)
        }
    }

    private fun stopDetachedSession(app: Context, call: MethodCall, result: MethodChannel.Result) {
        // A disconnect already requested by Dart must still finish if Android
        // destroys the window before the asynchronous channel call arrives.
        val manual = call.argument<Boolean>("recordManualStop") != false
        val service = SsrvpnVpnService.instance
        if (service == null) {
            if (manual && !VpnServiceRestartStore.recordManualStop(app)) {
                result.error("STOP_FAILED", "无法保存断开状态，请返回应用重试", null)
                return
            }
            app.stopService(Intent(app, SsrvpnVpnService::class.java))
            result.success(true)
        } else {
            service.stopAll(preserveForegroundUi = true, recordManualStop = manual) { stopped ->
                handler.post {
                    AndroidRuntimeGuard.run("FlutterRuntime", "Unable to deliver VPN stop result") {
                        if (stopped) result.success(true)
                        else result.error("STOP_INCOMPLETE", "VPN 正在释放系统资源，请稍后重试", null)
                    }
                }
            }
        }
    }
}
