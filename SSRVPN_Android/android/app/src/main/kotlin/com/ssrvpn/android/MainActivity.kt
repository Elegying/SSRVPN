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
import io.flutter.plugin.common.MethodCall
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
    private var myResultCallback:
        ((Boolean, String, Map<String, Any?>?) -> Unit)? = null
    @Volatile
    private var myStartRequestId: String? = null
    @Volatile
    private var myStartClaimId: String? = null
    @Volatile
    private var myStartPayloadId: String? = null
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

        // 冷启动时（磁贴拉起）onNewIntent 不会触发。只接受本进程磁贴签发的
        // 一次性请求，并在读取后立即从 Intent 中移除，避免重建时重放。
        AndroidRuntimeGuard.run("MainActivity", "Unable to consume tile auto-connect") {
            enqueueTrustedAutoConnect(intent)
        }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel
        registerVpnStateReceiver()
        channel.setMethodCallHandler(::handleNativeMethodCall)
    }

    private fun runOnActiveUiThread(message: String, action: () -> Unit) {
        AndroidRuntimeGuard.run("MainActivity", "Unable to schedule UI callback") {
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                AndroidRuntimeGuard.run("MainActivity", message, operation = action)
            }
        }
    }

    private fun registerVpnStateReceiver() {
        if (vpnStateReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == VpnTileService.ACTION_VPN_STATE_CHANGED) {
                    val connected = intent.getBooleanExtra(
                        VpnTileService.EXTRA_CONNECTED,
                        false
                    )
                    Log.d("MainActivity", "VPN state broadcast: connected=$connected")
                    runOnActiveUiThread("Unable to deliver VPN state") {
                        methodChannel?.invokeMethod("vpnStateChanged", connected)
                    }
                }
            }
        }
        val filter = IntentFilter(VpnTileService.ACTION_VPN_STATE_CHANGED)
        val registered = AndroidRuntimeGuard.run(
            "MainActivity",
            "Unable to register VPN state receiver"
        ) {
            ContextCompat.registerReceiver(
                this,
                receiver,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
        }
        if (registered) vpnStateReceiver = receiver
    }

    private fun handleNativeMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getNativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
            "getAppDataDir" -> result.success(applicationInfo.dataDir)
            "isCoreRunning" -> result.success(SsrvpnVpnService.isRunning)
            "getConnectionState" ->
                result.success(NativeVpnSessionCoordinator.connectionState())
            "getNativeDiagnostics" -> Thread({
                val snapshot = try {
                    NativeVpnSessionCoordinator.diagnostics()
                } catch (_: Exception) {
                    null
                }
                runOnActiveUiThread("Unable to deliver native diagnostics") {
                    if (snapshot == null) {
                        result.error(
                            "NATIVE_DIAGNOSTICS_FAILED",
                            "Unable to read native diagnostics",
                            null
                        )
                    } else {
                        result.success(snapshot)
                    }
                }
            }, "SSRVPN-native-diagnostics").apply {
                isDaemon = true
                start()
            }
            "consumePendingAutoConnect" -> {
                val pending = autoConnectPending
                autoConnectPending = false
                result.success(pending)
            }
            "syncSettings" -> handleSyncSettings(call, result)
            "getConnectionSnapshotGeneration" -> handleSnapshotGeneration(result)
            "clearConnectionSnapshot" -> handleClearConnectionSnapshot(call, result)
            "prepareApiSecretRecovery" -> handlePrepareApiSecretRecovery(result)
            "notifyVpnStateChanged" -> {
                SsrvpnVpnService.broadcastState(this)
                result.success(true)
            }
            "startCoreWithVpn" -> handleStartCoreWithVpn(call, result)
            "stopCore" -> handleStopCore(result)
            "updateVpnNotification" -> handleUpdateVpnNotification(call, result)
            "openUrl" -> handleOpenUrl(call, result)
            "installUpdate" -> handleInstallUpdate(call, result)
            else -> result.notImplemented()
        }
    }

    private fun enqueueTrustedAutoConnect(sourceIntent: Intent?): Boolean {
        val requestId = sourceIntent?.getStringExtra(
            AutoConnectRequestRegistry.EXTRA_REQUEST_ID
        )
        sourceIntent?.removeExtra(AutoConnectRequestRegistry.EXTRA_REQUEST_ID)
        if (!AutoConnectRequestRegistry.consume(this, requestId)) return false
        autoConnectPending = true
        return true
    }

    private fun handleSnapshotGeneration(result: MethodChannel.Result) {
        try {
            result.success(NativeConnectionSnapshotStore.generation(this))
        } catch (error: Exception) {
            result.error(
                "NATIVE_SNAPSHOT_GENERATION_FAILED",
                "无法读取原生 VPN 快照代际",
                null
            )
        }
    }

    private fun handleClearConnectionSnapshot(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val args = call.arguments as? Map<*, *>
        if (args == null || !args.containsKey("expectedGeneration")) {
            result.error(
                "INVALID_SNAPSHOT_CLEAR",
                "缺少原生 VPN 快照代际",
                null
            )
            return
        }
        try {
            result.success(
                NativeVpnSessionCoordinator.clearIdleSnapshot(
                    this,
                    args["expectedGeneration"] as? String
                )
            )
        } catch (error: Exception) {
            result.error(
                "NATIVE_SNAPSHOT_CLEAR_FAILED",
                "无法清除原生 VPN 快速启动数据",
                null
            )
        }
    }

    private fun handlePrepareApiSecretRecovery(result: MethodChannel.Result) {
        try {
            result.success(NativeVpnSessionCoordinator.prepareApiSecretRecovery(this))
        } catch (error: Exception) {
            Log.e("MainActivity", "Unable to prepare API secret recovery", error)
            result.error(
                "API_SECRET_RECOVERY_PREPARE_FAILED",
                "无法安全清除旧连接状态",
                null
            )
        }
    }

    private fun handleSyncSettings(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val proxyPort = (args?.get("proxyPort") as? Number)?.toInt() ?: 7890
        val socksPort = (args?.get("socksPort") as? Number)?.toInt() ?: 7891
        val configDir = args?.get("configDir") as? String
        val configPath = args?.get("configPath") as? String
        val apiPort = (args?.get("apiPort") as? Number)?.toInt()
        val apiSecret = args?.get("apiSecret") as? String
        val selectedNodeName = args?.get("selectedNodeName") as? String
        try {
            val snapshot = NativeConnectionSnapshot(
                configDir = configDir.orEmpty(),
                configPath = configPath.orEmpty(),
                apiPort = apiPort ?: 0,
                apiSecret = apiSecret.orEmpty(),
                selectedNodeName = selectedNodeName
            )
            val expectedSessionGeneration =
                (args?.get("expectedSessionGeneration") as? Number)?.toLong()
            val generation = if (expectedSessionGeneration == null) {
                NativeVpnSessionCoordinator.commitIdleSnapshot(this, snapshot)
                    ?: throw IllegalStateException(
                        "Active native VPN session requires a generation"
                    )
            } else {
                SsrvpnVpnService.instance?.commitConnectionSnapshot(
                    expectedSessionGeneration,
                    snapshot
                ) ?: throw IllegalStateException("Native VPN session changed")
            }
            result.success(generation)
        } catch (error: Exception) {
            Log.e("MainActivity", "Unable to sync native VPN snapshot", error)
            result.error(
                "NATIVE_SNAPSHOT_SYNC_FAILED",
                "无法同步原生 VPN 快速启动数据",
                null
            )
            return
        }

        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit()
            .putLong("flutter.proxyPort", proxyPort.toLong())
            .putLong("flutter.socksPort", socksPort.toLong())
            .apply()
    }

    private fun handleStartCoreWithVpn(call: MethodCall, result: MethodChannel.Result) {
        if (SsrvpnVpnService.isCoreOperationBusy()) {
            result.error("CORE_BUSY", "VPN 核心正在启动或停止，请稍后重试", null)
            return
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
            return
        }

        Log.d(
            "MainActivity",
            "startCoreWithVpn: dir=$configDir, config=$configPath, apiPort=$apiPort"
        )
        val completed = AtomicBoolean(false)
        lateinit var callback: (Boolean, String, Map<String, Any?>?) -> Unit
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
            NativeVpnSessionCoordinator.releasePendingStart(myStartClaimId)
            myStartClaimId = null
            NativeStartPayloadRegistry.discard(myStartPayloadId)
            myStartPayloadId = null
            VpnStartResultRegistry.clear(requestId)
            try {
                SsrvpnVpnService.instance?.stopAll()
            } catch (error: Exception) {
                Log.w(
                    "MainActivity",
                    "VPN start timeout cleanup failed: ${error.javaClass.simpleName}"
                )
            }
            runOnActiveUiThread("Unable to deliver VPN start timeout") {
                result.error("CORE_TIMEOUT", "设备性能不足，请重新连接", null)
            }
        }
        callback = callback@{ success, message, capturedState ->
            if (!completed.compareAndSet(false, true)) return@callback
            Log.d(
                "MainActivity",
                "VPN start result: success=$success " +
                    "running=${capturedState?.get("running")} " +
                    "transitioning=${capturedState?.get("transitioning")} " +
                    "configTrusted=${capturedState?.get("protectedConfigTrusted")} " +
                    "hasGeneration=${capturedState?.get("sessionGeneration") != null}"
            )
            vpnPermissionRequestPending = false
            mainHandler.removeCallbacks(timeoutRunnable)
            if (startTimeoutRunnable === timeoutRunnable) {
                startTimeoutRunnable = null
            }
            VpnStartResultRegistry.clear(requestId)
            NativeVpnSessionCoordinator.releasePendingStart(myStartClaimId)
            myStartClaimId = null
            NativeStartPayloadRegistry.discard(myStartPayloadId)
            myStartPayloadId = null
            myResultCallback = null
            myStartRequestId = null
            runOnActiveUiThread("Unable to deliver VPN start result") {
                if (success) {
                    requestNotificationPermissionOnce()
                    result.success(capturedState)
                } else {
                    val errorCode = if (message == "用户拒绝了 VPN 权限") {
                        "PERMISSION_DENIED"
                    } else {
                        "CORE_FAILED"
                    }
                    result.error(errorCode, message, null)
                }
            }
        }
        myResultCallback = callback
        requestId = VpnStartResultRegistry.register(callback)
        myStartRequestId = requestId
        val startPayload = try {
            NativeConnectionPathPolicy.requireTrusted(
                applicationInfo.dataDir,
                NativeConnectionSnapshot(
                    configDir = configDir,
                    configPath = configPath,
                    apiPort = apiPort,
                    apiSecret = apiSecret,
                    selectedNodeName = nodeName
                )
            )
        } catch (error: Exception) {
            VpnStartResultRegistry.clear(requestId)
            myResultCallback = null
            myStartRequestId = null
            result.error("INVALID_CONFIG_PATH", "VPN 配置路径不安全或不可用", null)
            return
        }
        myStartPayloadId = NativeStartPayloadRegistry.register(startPayload)
        pendingVpnServiceIntent = SsrvpnVpnService.createStartIntent(
            this,
            requestId = requestId,
            startPayloadId = myStartPayloadId
        )
        startTimeoutRunnable = timeoutRunnable

        try {
            val vpnIntent = VpnService.prepare(this)
            if (vpnIntent != null) {
                Log.d("MainActivity", "Requesting VPN permission...")
                vpnPermissionRequestPending = true
                startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
            } else {
                Log.d("MainActivity", "VPN permission already granted, starting service...")
                startVpnServiceWithTimeout()
            }
        } catch (error: Exception) {
            Log.e("MainActivity", "Unable to request VPN permission", error)
            cancelPendingActivityStart("无法打开 VPN 授权页面，请检查系统设置后重试")
        }
    }

    private fun handleStopCore(result: MethodChannel.Result) {
        Log.d("MainActivity", "Stopping core...")
        try {
            cancelPendingActivityStart("连接已取消")
            val service = SsrvpnVpnService.instance
            if (service == null) {
                if (!VpnServiceRestartStore.recordManualStop(this)) {
                    Log.e("MainActivity", "Unable to persist manual VPN disconnect")
                }
                stopService(Intent(this, SsrvpnVpnService::class.java))
                result.success(true)
            } else {
                service.stopAll(
                    preserveForegroundUi = true,
                    recordManualStop = true
                ) {
                    runOnActiveUiThread("Unable to deliver VPN stop result") {
                        result.success(true)
                    }
                }
            }
        } catch (error: Exception) {
            result.error("STOP_FAILED", error.message, null)
        }
    }

    private fun handleUpdateVpnNotification(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val nodeName = call.argument<String>("nodeName")
        val expectedSessionGeneration =
            call.argument<Number>("expectedSessionGeneration")?.toLong()
        if (nodeName.isNullOrBlank()) {
            result.error("INVALID_ARGS", "Node name is required", null)
            return
        }
        val service = SsrvpnVpnService.instance
        if (expectedSessionGeneration == null ||
            service == null ||
            !service.updateNotificationNode(nodeName, expectedSessionGeneration)
        ) {
            result.error(
                "NATIVE_SNAPSHOT_UPDATE_FAILED",
                "无法更新原生 VPN 节点快照",
                null
            )
            return
        }
        result.success(true)
    }

    private fun handleOpenUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = ExternalUrlPolicy.normalizedHttpUrl(
            call.argument<String>("url")
        )
        if (url == null) {
            result.error("INVALID_URL", "Only HTTP and HTTPS URLs are allowed", null)
            return
        }
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            result.success(true)
        } catch (error: Exception) {
            result.error("OPEN_URL_FAILED", error.message, null)
        }
    }

    private fun handleInstallUpdate(call: MethodCall, result: MethodChannel.Result) {
        val apkPath = call.argument<String>("apkPath")
        if (apkPath.isNullOrBlank()) {
            result.error("INVALID_ARGS", "APK path is required", null)
            return
        }
        try {
            result.success(mapOf("status" to requestUpdateInstall(apkPath)))
        } catch (error: Exception) {
            result.error("INSTALL_UPDATE_FAILED", error.message, null)
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
        val claimId = NativeVpnSessionCoordinator.claimPendingStart(serviceIntent)
        if (claimId == null) {
            cancelPendingActivityStart("VPN 启动状态已变化，请重试")
            return
        }
        myStartClaimId = claimId
        try {
            startVpnService(serviceIntent)
        } catch (error: Exception) {
            Log.e("MainActivity", "Unable to start VPN service", error)
            cancelPendingActivityStart("无法启动 VPN 服务，请重试")
        }
    }

    private fun cancelPendingActivityStart(message: String) {
        vpnPermissionRequestPending = false
        startTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        startTimeoutRunnable = null
        pendingVpnServiceIntent = null
        NativeVpnSessionCoordinator.releasePendingStart(myStartClaimId)
        myStartClaimId = null
        NativeStartPayloadRegistry.discard(myStartPayloadId)
        myStartPayloadId = null
        myResultCallback?.invoke(false, message, null)
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
        AndroidRuntimeGuard.run("MainActivity", "Pending update install failed") {
            continuePendingUpdateInstallIfAllowed()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        var autoConnect = false
        if (!AndroidRuntimeGuard.run("MainActivity", "Unable to consume tile auto-connect") {
                autoConnect = enqueueTrustedAutoConnect(intent)
            }
        ) return
        if (autoConnect) {
            Log.d("MainActivity", "Auto connect from tile!")
            // 这里只唤醒 Flutter；同一个 pending 位由 Dart 原子消费，避免
            // MethodChannel 回调与页面初始化各触发一次连接切换。
            runOnActiveUiThread("Unable to deliver tile auto-connect") {
                methodChannel?.invokeMethod("autoConnect", null)
            }
        }
    }

    override fun onDestroy() {
        vpnPermissionRequestPending = false
        startTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        startTimeoutRunnable = null
        pendingVpnServiceIntent = null
        NativeVpnSessionCoordinator.releasePendingStart(myStartClaimId)
        myStartClaimId = null
        NativeStartPayloadRegistry.discard(myStartPayloadId)
        myStartPayloadId = null
        // 只清理本 Activity 注册的回调，避免静态引用泄漏 Activity；
        // 不影响磁贴等其他来源设置的回调
        VpnStartResultRegistry.clear(myStartRequestId)
        myStartRequestId = null
        myResultCallback = null
        vpnStateReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        vpnStateReceiver = null
        methodChannel = null
        super.onDestroy()
    }
}
