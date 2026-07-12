package com.ssrvpn.android

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.ssrvpn/native"
    private val VPN_REQUEST_CODE = 100
    private val NOTIFICATION_PERMISSION_REQUEST_CODE = 101
    private val NOTIFICATION_PERMISSION_PREFS = "ssrvpn_notification"
    private val NOTIFICATION_PERMISSION_REQUESTED = "notification_permission_requested"
    private val UPDATE_PREFS = "ssrvpn_update"
    private val PENDING_UPDATE_APK_PATH = "pending_update_apk_path"
    private var autoConnectPending = false
    // 记录本 Activity 注册的回调，便于 onDestroy 时精确清理，避免泄漏 Activity
    @Volatile
    private var myResultCallback: ((Boolean, String) -> Unit)? = null
    @Volatile
    private var myStartRequestId: String? = null
    private var methodChannel: MethodChannel? = null
    // 监听 VPN 状态广播（磁贴断开/连接），实时推送给 Flutter 更新 UI
    private var vpnStateReceiver: BroadcastReceiver? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var startTimeoutRunnable: Runnable? = null
    @Volatile
    private var pendingVpnServiceIntent: Intent? = null
    @Volatile
    private var vpnPermissionRequestPending = false

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
            ContextCompat.registerReceiver(
                this,
                receiver,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
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
                "syncSettings" -> {
                    val args = call.arguments as? Map<*, *>
                    val proxyPort = (args?.get("proxyPort") as? Number)?.toInt() ?: 7890

                    getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        .edit()
                        .putLong("flutter.proxyPort", proxyPort.toLong())
                        .apply()

                    result.success(true)
                }
                "notifyVpnStateChanged" -> {
                    // Flutter 通知原生状态变更，广播给磁贴和通知
                    SsrvpnVpnService.broadcastState(this)
                    result.success(true)
                }
                "startCoreWithVpn" -> {
                    if (SsrvpnVpnService.isCoreOperationBusy()) {
                        result.error(
                            "CORE_BUSY",
                            "VPN 核心正在启动或停止，请稍后重试",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    cancelPendingActivityStart("新的连接请求已替代旧请求")
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

                    val completed = AtomicBoolean(false)
                    lateinit var callback: (Boolean, String) -> Unit
                    lateinit var timeoutRunnable: Runnable
                    lateinit var requestId: String
                    timeoutRunnable = Runnable {
                        if (!completed.compareAndSet(false, true)) return@Runnable
                        vpnPermissionRequestPending = false
                        if (startTimeoutRunnable === timeoutRunnable) {
                            startTimeoutRunnable = null
                        }
                        myResultCallback = null
                        myStartRequestId = null
                        SsrvpnVpnService.clearStartResultCallback(requestId)
                        try {
                            SsrvpnVpnService.instance?.stopAll()
                        } catch (_: Exception) {}
                        runOnUiThread {
                            result.error("CORE_TIMEOUT", "设备性能不足，请重新连接", null)
                        }
                    }
                    callback = callback@{ success, message ->
                        if (!completed.compareAndSet(false, true)) return@callback
                        vpnPermissionRequestPending = false
                        mainHandler.removeCallbacks(timeoutRunnable)
                        if (startTimeoutRunnable === timeoutRunnable) {
                            startTimeoutRunnable = null
                        }
                        SsrvpnVpnService.clearStartResultCallback(requestId)
                        myResultCallback = null
                        myStartRequestId = null
                        runOnUiThread {
                            if (success) {
                                requestNotificationPermissionOnce()
                                result.success(true)
                            } else {
                                result.error("CORE_FAILED", message, null)
                            }
                        }
                    }
                    myResultCallback = callback
                    requestId = SsrvpnVpnService.registerStartResultCallback(callback)
                    myStartRequestId = requestId
                    pendingVpnServiceIntent = SsrvpnVpnService.createStartIntent(
                        this,
                        configDir,
                        configPath,
                        apiPort,
                        apiSecret,
                        nodeName,
                        requestId
                    )
                    startTimeoutRunnable = timeoutRunnable

                    val vpnIntent = VpnService.prepare(this)
                    if (vpnIntent != null) {
                        Log.d("MainActivity", "Requesting VPN permission...")
                        vpnPermissionRequestPending = true
                        startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
                    } else {
                        Log.d("MainActivity", "VPN permission already granted, starting service...")
                        startVpnServiceWithTimeout()
                    }
                }
                "stopCore" -> {
                    Log.d("MainActivity", "Stopping core...")
                    try {
                        cancelPendingActivityStart("连接已取消")
                        val service = SsrvpnVpnService.instance
                        if (service == null) {
                            stopService(Intent(this, SsrvpnVpnService::class.java))
                            result.success(true)
                        } else {
                            service.stopAll {
                                runOnUiThread { result.success(true) }
                            }
                        }
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
                "installUpdate" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "APK path is required", null)
                    } else {
                        try {
                            result.success(mapOf("status" to requestUpdateInstall(apkPath)))
                        } catch (e: Exception) {
                            result.error("INSTALL_UPDATE_FAILED", e.message, null)
                        }
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun requestUpdateInstall(apkPath: String): String {
        val apkFile = File(apkPath)
        require(apkFile.exists() && apkFile.isFile) { "APK file not found" }
        require(apkFile.name.endsWith(".apk", ignoreCase = true)) { "Invalid APK file" }
        UpdateApkVerifier.verify(packageManager, packageName, apkFile)

        if (!canRequestUpdateInstall()) {
            savePendingUpdateInstall(apkFile.absolutePath)
            openInstallSourceSettings()
            return "permissionRequired"
        }

        clearPendingUpdateInstall()
        launchPackageInstaller(apkFile)
        return "started"
    }

    private fun canRequestUpdateInstall(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()
    }

    private fun savePendingUpdateInstall(apkPath: String) {
        getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(PENDING_UPDATE_APK_PATH, apkPath)
            .apply()
    }

    private fun clearPendingUpdateInstall() {
        getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(PENDING_UPDATE_APK_PATH)
            .apply()
    }

    private fun openInstallSourceSettings() {
        val settingsIntent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName")
        )
        try {
            startActivity(settingsIntent)
        } catch (_: ActivityNotFoundException) {
            startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
        }
    }

    private fun continuePendingUpdateInstallIfAllowed() {
        if (!canRequestUpdateInstall()) return
        val prefs = getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
        val apkPath = prefs.getString(PENDING_UPDATE_APK_PATH, null) ?: return
        val apkFile = File(apkPath)
        if (!apkFile.exists() || !apkFile.isFile) {
            clearPendingUpdateInstall()
            return
        }

        try {
            clearPendingUpdateInstall()
            launchPackageInstaller(apkFile)
        } catch (e: Exception) {
            Log.e("MainActivity", "Pending update install failed: ${e.message}", e)
        }
    }

    @Suppress("DEPRECATION")
    private fun launchPackageInstaller(apkFile: File) {
        // Re-check immediately before handing the file to Android so a pending
        // install cannot bypass package/signing identity validation.
        UpdateApkVerifier.verify(packageManager, packageName, apkFile)
        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apkFile
        )
        val installIntent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setDataAndType(apkUri, "application/vnd.android.package-archive")
            clipData = ClipData.newUri(contentResolver, "SSRVPN update", apkUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            putExtra(Intent.EXTRA_RETURN_RESULT, false)
        }
        startActivity(installIntent)
    }

    private fun startVpnService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun requestNotificationPermissionOnce() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val prefs = getSharedPreferences(NOTIFICATION_PERMISSION_PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(NOTIFICATION_PERMISSION_REQUESTED, false)) return

        prefs.edit().putBoolean(NOTIFICATION_PERMISSION_REQUESTED, true).apply()
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE
        )
    }

    private fun startVpnServiceWithTimeout() {
        val timeoutRunnable = startTimeoutRunnable ?: return
        val serviceIntent = pendingVpnServiceIntent ?: run {
            cancelPendingActivityStart("连接参数已失效，请重试")
            return
        }
        pendingVpnServiceIntent = null
        mainHandler.removeCallbacks(timeoutRunnable)
        mainHandler.postDelayed(timeoutRunnable, 55000L)
        startVpnService(serviceIntent)
    }

    private fun cancelPendingActivityStart(message: String) {
        vpnPermissionRequestPending = false
        startTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        startTimeoutRunnable = null
        pendingVpnServiceIntent = null
        myResultCallback?.invoke(false, message)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST_CODE) {
            if (!vpnPermissionRequestPending) {
                Log.w("MainActivity", "Ignoring stale VPN permission result")
                return
            }
            vpnPermissionRequestPending = false
            if (resultCode == Activity.RESULT_OK) {
                Log.d("MainActivity", "VPN permission granted!")
                startVpnServiceWithTimeout()
            } else {
                Log.e("MainActivity", "VPN permission denied!")
                cancelPendingActivityStart("用户拒绝了 VPN 权限")
            }
        }
    }

    override fun onResume() {
        super.onResume()
        continuePendingUpdateInstallIfAllowed()
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
        vpnPermissionRequestPending = false
        startTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        startTimeoutRunnable = null
        pendingVpnServiceIntent = null
        // 只清理本 Activity 注册的回调，避免静态引用泄漏 Activity；
        // 不影响磁贴等其他来源设置的回调
        SsrvpnVpnService.clearStartResultCallback(myStartRequestId)
        myStartRequestId = null
        myResultCallback = null
        vpnStateReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        vpnStateReceiver = null
        methodChannel = null
        super.onDestroy()
    }
}
