package com.ssrvpn.android

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.ssrvpn/native"
    private val VPN_REQUEST_CODE = 100
    private var autoConnectPending = false
    // 记录本 Activity 注册的回调，便于 onDestroy 时精确清理，避免泄漏 Activity
    private var myResultCallback: ((Boolean, String) -> Unit)? = null
    private var methodChannel: MethodChannel? = null
    // 监听 VPN 状态广播（磁贴断开/连接），实时推送给 Flutter 更新 UI
    private var vpnStateReceiver: BroadcastReceiver? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var startTimeoutRunnable: Runnable? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 冷启动时（磁贴拉起）onNewIntent 不会触发，从启动 intent 里读取标记，
        // 由 Flutter 层初始化完成后调用 consumePendingAutoConnect 消费
        if (intent?.getBooleanExtra("AUTO_CONNECT", false) == true) {
            autoConnectPending = true
        }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel

        // 注册 VPN 状态广播接收器，磁贴操作时实时同步 Flutter UI
        if (vpnStateReceiver == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent?.action == VpnTileService.ACTION_VPN_STATE_CHANGED) {
                        val connected = intent.getBooleanExtra(VpnTileService.EXTRA_CONNECTED, false)
                        Log.d("MainActivity", "VPN state broadcast: connected=$connected")
                        runOnUiThread {
                            methodChannel?.invokeMethod("vpnStateChanged", connected)
                        }
                    }
                }
            }
            val filter = IntentFilter(VpnTileService.ACTION_VPN_STATE_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(receiver, filter)
            }
            vpnStateReceiver = receiver
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getNativeLibraryDir" -> {
                    result.success(applicationInfo.nativeLibraryDir)
                }
                "getAppDataDir" -> {
                    result.success(applicationInfo.dataDir)
                }
                "isCoreRunning" -> {
                    result.success(SsrvpnVpnService.isRunning)
                }
                "consumePendingAutoConnect" -> {
                    val pending = autoConnectPending
                    autoConnectPending = false
                    result.success(pending)
                }
                "notifyVpnStateChanged" -> {
                    // Flutter 通知原生状态变更，广播给磁贴和通知
                    SsrvpnVpnService.broadcastState(this)
                    result.success(true)
                }
                "startCoreWithVpn" -> {
                    val args = call.arguments as? Map<*, *>
                    val configDir = args?.get("configDir") as? String
                    val configPath = args?.get("configPath") as? String
                    val apiPort = args?.get("apiPort") as? Int ?: 9090
                    val apiSecret = args?.get("apiSecret") as? String ?: ""
                    val nodeName = args?.get("nodeName") as? String

                    if (configDir == null || configPath == null) {
                        result.error("INVALID_ARGS", "Missing required arguments", null)
                        return@setMethodCallHandler
                    }

                    Log.d("MainActivity", "startCoreWithVpn: dir=$configDir, config=$configPath, apiPort=$apiPort")

                    SsrvpnVpnService.pendingConfigDir = configDir
                    SsrvpnVpnService.pendingConfigPath = configPath
                    SsrvpnVpnService.pendingApiPort = apiPort
                    SsrvpnVpnService.pendingApiSecret = apiSecret
                    SsrvpnVpnService.pendingNodeName = nodeName

                    var completed = false
                    lateinit var callback: (Boolean, String) -> Unit
                    val timeoutRunnable = Runnable {
                        if (completed) return@Runnable
                        completed = true
                        myResultCallback = null
                        SsrvpnVpnService.clearStartResultCallback(callback)
                        try {
                            SsrvpnVpnService.instance?.stopAll()
                        } catch (_: Exception) {}
                        runOnUiThread {
                            result.error("CORE_TIMEOUT", "设备性能不足，请重新连接", null)
                        }
                    }
                    callback = callback@{ success, message ->
                        if (completed) return@callback
                        completed = true
                        mainHandler.removeCallbacks(timeoutRunnable)
                        if (startTimeoutRunnable === timeoutRunnable) {
                            startTimeoutRunnable = null
                        }
                        myResultCallback = null
                        runOnUiThread {
                            if (success) {
                                result.success(true)
                            } else {
                                result.error("CORE_FAILED", message, null)
                            }
                        }
                    }
                    myResultCallback = callback
                    SsrvpnVpnService.setStartResultCallback(callback)
                    startTimeoutRunnable = timeoutRunnable
                    mainHandler.postDelayed(timeoutRunnable, 55000L)

                    val vpnIntent = VpnService.prepare(this)
                    if (vpnIntent != null) {
                        Log.d("MainActivity", "Requesting VPN permission...")
                        startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
                    } else {
                        Log.d("MainActivity", "VPN permission already granted, starting service...")
                        startVpnService()
                    }
                }
                "stopCore" -> {
                    Log.d("MainActivity", "Stopping core...")
                    try {
                        SsrvpnVpnService.instance?.stopAll()
                        val intent = Intent(this, SsrvpnVpnService::class.java)
                        stopService(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_FAILED", e.message, null)
                    }
                }
                "updateVpnNotification" -> {
                    val nodeName = call.argument<String>("nodeName")
                    if (nodeName.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "Node name is required", null)
                    } else {
                        SsrvpnVpnService.instance?.updateNotificationNode(nodeName)
                        result.success(true)
                    }
                }
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        try {
                            val browserIntent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                            startActivity(browserIntent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_URL_FAILED", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARGS", "URL is required", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun startVpnService() {
        val intent = Intent(this, SsrvpnVpnService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                Log.d("MainActivity", "VPN permission granted!")
                startVpnService()
            } else {
                Log.e("MainActivity", "VPN permission denied!")
                SsrvpnVpnService.completeStartResult(false, "用户拒绝了 VPN 权限")
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra("AUTO_CONNECT", false)) {
            Log.d("MainActivity", "Auto connect from tile!")
            autoConnectPending = true
            // 通过 Flutter MethodChannel 通知 Flutter 层自动连接
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, CHANNEL).invokeMethod("autoConnect", null)
            }
        }
    }

    override fun onDestroy() {
        startTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        startTimeoutRunnable = null
        // 只清理本 Activity 注册的回调，避免静态引用泄漏 Activity；
        // 不影响磁贴等其他来源设置的回调
        SsrvpnVpnService.clearStartResultCallback(myResultCallback)
        myResultCallback = null
        vpnStateReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        vpnStateReceiver = null
        methodChannel = null
        super.onDestroy()
    }
}
