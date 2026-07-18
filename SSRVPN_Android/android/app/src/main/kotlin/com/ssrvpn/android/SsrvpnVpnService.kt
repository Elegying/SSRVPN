package com.ssrvpn.android

import android.app.Notification
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.net.TrafficStats
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

private class StartCancelledException : Exception("VPN start cancelled")

class SsrvpnVpnService : VpnService() {
    companion object {
        private const val TAG = "SsrvpnVpn"
        private const val CHANNEL_ID = "ssrvpn_vpn"
        private const val NOTIFICATION_ID = 1
        private const val RECOVERY_FAILURE_NOTIFICATION_ID = 2

        const val ACTION_DISCONNECT = "com.ssrvpn.ACTION_DISCONNECT"
        const val ACTION_CONNECT = "com.ssrvpn.ACTION_CONNECT"
        private const val EXTRA_CONFIG_DIR = "com.ssrvpn.extra.CONFIG_DIR"
        internal const val EXTRA_CONFIG_PATH = "com.ssrvpn.extra.CONFIG_PATH"
        private const val EXTRA_API_PORT = "com.ssrvpn.extra.API_PORT"
        private const val EXTRA_API_SECRET = "com.ssrvpn.extra.API_SECRET"
        private const val EXTRA_NODE_NAME = "com.ssrvpn.extra.NODE_NAME"
        private const val EXTRA_REQUEST_ID = "com.ssrvpn.extra.REQUEST_ID"
        internal const val EXTRA_START_CLAIM_ID = "com.ssrvpn.extra.START_CLAIM_ID"
        private const val EXTRA_RECOVERY_ATTEMPT = "com.ssrvpn.extra.RECOVERY_ATTEMPT"
        private const val EXTRA_RECOVERY_TOKEN = "com.ssrvpn.extra.RECOVERY_TOKEN"

        @Volatile
        var isRunning = false
            private set
        @Volatile
        var instance: SsrvpnVpnService? = null
            private set
        fun createStartIntent(
            context: Context,
            configDir: String,
            configPath: String,
            apiPort: Int,
            apiSecret: String,
            nodeName: String?,
            requestId: String? = null,
            startClaimId: String? = null,
            recoveryAttempt: Int = 0,
            recoveryToken: Long? = null
        ): Intent = Intent(context, SsrvpnVpnService::class.java).apply {
            putExtra(EXTRA_CONFIG_DIR, configDir)
            putExtra(EXTRA_CONFIG_PATH, configPath)
            putExtra(EXTRA_API_PORT, apiPort)
            putExtra(EXTRA_API_SECRET, apiSecret)
            putExtra(EXTRA_NODE_NAME, nodeName)
            putExtra(EXTRA_REQUEST_ID, requestId)
            startClaimId?.let { putExtra(EXTRA_START_CLAIM_ID, it) }
            putExtra(EXTRA_RECOVERY_ATTEMPT, recoveryAttempt)
            recoveryToken?.let { putExtra(EXTRA_RECOVERY_TOKEN, it) }
        }

        private fun consumeStartResult(
            requestId: String?,
            success: Boolean,
            message: String,
            state: Map<String, Any?>? = null
        ) = VpnStartResultRegistry.consume(requestId, success, message, state)

        /** 广播 VPN 状态变更 */
        fun broadcastState(context: Context) {
            val intent = Intent(VpnTileService.ACTION_VPN_STATE_CHANGED)
            intent.putExtra(VpnTileService.EXTRA_CONNECTED, isRunning)
            // Android 14+ 隐式广播不会投递给 NOT_EXPORTED 接收器，必须显式指定包名
            intent.setPackage(context.packageName)
            context.sendBroadcast(intent)
        }

        private const val BRIDGE_START_TIMEOUT_MS = 45_000L
        private const val PENDING_START_CANCEL_GRACE_MS = 1_000L
        private const val API_HEALTH_TIMEOUT_MS = 20_000L
        private const val API_HEALTH_POLL_INTERVAL_MS = 250L
        private const val BRIDGE_STOP_TIMEOUT_MS = 5_000L
        private const val BRIDGE_IS_RUNNING_TIMEOUT_MS = 2_000L
        private val stopOperation = CoalescedOperation()
        private val serviceStartInProgress = AtomicBoolean(false)
        private val bridgeStartInProgress = AtomicBoolean(false)
        private val bridgeStopInProgress = AtomicBoolean(false)
        private val bridgeRunningCheckInProgress = AtomicBoolean(false)
        private val processTerminationPending = AtomicBoolean(false)
        internal val startGeneration = StartGenerationGate()
        private val recoveryGeneration = AtomicLong(0)
        private val manualStopRequested = AtomicBoolean(false)

        fun isCoreOperationBusy(): Boolean =
            stopOperation.isRunning ||
                serviceStartInProgress.get() ||
                bridgeStartInProgress.get() ||
                bridgeStopInProgress.get() ||
                processTerminationPending.get()

        fun cancelPendingStart() {
            startGeneration.invalidate { isRunning = false }
            instance?.stopAll()
        }
    }

    private val disconnectReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_DISCONNECT) {
                Log.d(TAG, "Received disconnect from notification")
                stopAll()
                val stopIntent = Intent(this@SsrvpnVpnService, SsrvpnVpnService::class.java)
                stopService(stopIntent)
            }
        }
    }

    private var vpnFd: ParcelFileDescriptor? = null
    private var protectThread: Thread? = null
    @Volatile
    private var serviceStartThread: Thread? = null
    private val notificationHandler = Handler(Looper.getMainLooper())
    private var currentNodeName = "SSRVPN"
    private var connectionStartedAt = 0L
    private val nativeSessionCommitter by lazy {
        NativeSessionCommitter(this, startGeneration, { isRunning }) {
            currentNodeName = it
        }
    }
    private val trafficTracker by lazy {
        VpnTrafficTracker(
            { TrafficStats.getUidTxBytes(applicationInfo.uid) },
            { TrafficStats.getUidRxBytes(applicationInfo.uid) },
            SystemClock::elapsedRealtime
        )
    }
    private var notificationConnected = false
    private var notificationStatusText: String? = null
    private val notificationUpdatePolicy = NotificationUpdatePolicy()
    private val notificationGeneration = NotificationGenerationGate()
    private val mihomoApiWaiter = MihomoApiWaiter()
    private val screenStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    notificationUpdatePolicy.onScreenStateChanged(false)
                    notificationHandler.removeCallbacks(notificationUpdater)
                }
                Intent.ACTION_SCREEN_ON -> {
                    notificationUpdatePolicy.onScreenStateChanged(true)
                    if (isRunning && notificationConnected) {
                        notificationHandler.removeCallbacks(notificationUpdater)
                        trafficTracker.resetSample()
                        notifyCurrentState()
                        notificationHandler.postDelayed(
                            notificationUpdater,
                            notificationUpdatePolicy.initialRefreshDelayMillis
                        )
                    }
                }
            }
        }
    }
    private val notificationUpdater = object : Runnable {
        override fun run() {
            if (!isRunning || !notificationUpdatePolicy.shouldScheduleTrafficRefresh()) return
            trafficTracker.update(notificationUpdatePolicy::bytesPerSecond)
            notifyCurrentState()
            notificationHandler.postDelayed(
                this,
                notificationUpdatePolicy.refreshIntervalMillis
            )
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        VpnNotificationSupport.createChannel(this, CHANNEL_ID)
        // 注册断开广播
        val filter = IntentFilter(ACTION_DISCONNECT)
        ContextCompat.registerReceiver(
            this,
            disconnectReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        ContextCompat.registerReceiver(
            this,
            screenStateReceiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        notificationUpdatePolicy.onScreenStateChanged(isScreenInteractive())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "VPN Service starting...")
        val requestId = intent?.getStringExtra(EXTRA_REQUEST_ID)
        val startClaimId = intent?.getStringExtra(EXTRA_START_CLAIM_ID)
        val recoveryAttempt = intent?.getIntExtra(EXTRA_RECOVERY_ATTEMPT, 0) ?: 0
        val recoveryToken = if (intent?.hasExtra(EXTRA_RECOVERY_TOKEN) == true) {
            intent.getLongExtra(EXTRA_RECOVERY_TOKEN, -1L)
        } else {
            null
        }

        if (recoveryAttempt > 0 && !CoreRecoveryPolicy.shouldAcceptRestart(
                recoveryAttempt,
                recoveryToken,
                recoveryGeneration.get(),
                manualStopRequested.get()
            )
        ) {
            Log.w(TAG, "Ignoring obsolete VPN recovery request")
            NativeVpnSessionCoordinator.releasePendingStart(startClaimId)
            consumeStartResult(requestId, false, "自动恢复请求已失效")
            stopSelfResult(startId)
            return START_NOT_STICKY
        }

        if (isRunning) {
            Log.d(TAG, "VPN is already running; reusing the active session")
            NativeVpnSessionCoordinator.releasePendingStart(startClaimId)
            consumeStartResult(requestId, true, "Already running",
                NativeVpnSessionCoordinator.connectionState())
            return START_STICKY
        }
        if (stopOperation.isRunning || processTerminationPending.get()) {
            Log.w(TAG, "VPN cleanup is still in progress")
            NativeVpnSessionCoordinator.releasePendingStart(startClaimId)
            consumeStartResult(requestId, false, "VPN 核心正在清理，请稍后重试")
            return START_NOT_STICKY
        }
        if (!serviceStartInProgress.compareAndSet(false, true)) {
            Log.w(TAG, "VPN start already in progress")
            NativeVpnSessionCoordinator.releasePendingStart(startClaimId)
            consumeStartResult(requestId, false, "VPN 核心正在启动，请稍后重试")
            return START_STICKY
        }
        manualStopRequested.set(false)
        val startToken = NativeVpnSessionCoordinator.beginStart(startClaimId)
        if (startToken == null) {
            serviceStartInProgress.set(false)
            consumeStartResult(requestId, false, "VPN 启动租约已失效")
            return START_NOT_STICKY
        }

        val explicitConfigDir = intent?.getStringExtra(EXTRA_CONFIG_DIR)
        val explicitConfigPath = intent?.getStringExtra(EXTRA_CONFIG_PATH)
        val hasExplicitApiPort = intent?.hasExtra(EXTRA_API_PORT) == true
        val explicitApiSecret = intent?.getStringExtra(EXTRA_API_SECRET)
        val needsSnapshot = explicitConfigDir == null ||
            explicitConfigPath == null ||
            !hasExplicitApiPort ||
            explicitApiSecret.isNullOrBlank()
        val snapshot = if (needsSnapshot) {
            NativeConnectionSnapshotStore.read(this)
        } else {
            null
        }
        val configDir = explicitConfigDir ?: snapshot?.configDir
        val configPath = explicitConfigPath ?: snapshot?.configPath
        val apiPort = if (hasExplicitApiPort) {
            intent.getIntExtra(EXTRA_API_PORT, 9090)
        } else {
            snapshot?.apiPort ?: 9090
        }
        val apiSecret = NativeApiSecretResolver.resolve(explicitApiSecret) {
            snapshot?.apiSecret
        }
        configPath?.let(NativeConnectionSession::reserveStarting)

        currentNodeName = intent?.getStringExtra(EXTRA_NODE_NAME)
            ?: snapshot?.selectedNodeName
            ?: "SSRVPN"
        connectionStartedAt = System.currentTimeMillis()
        notificationConnected = false
        notificationStatusText = if (recoveryAttempt > 0) {
            CoreRecoveryPolicy.recoveringMessage(recoveryAttempt)
        } else {
            null
        }
        getSystemService(NotificationManager::class.java)
            .cancel(RECOVERY_FAILURE_NOTIFICATION_ID)
        trafficTracker.reset()

        notificationUpdatePolicy.resetPublishedState()
        val initialNotificationState = currentNotificationState()
        val notification = buildDynamicNotification(initialNotificationState)
        notificationUpdatePolicy.markPublished(initialNotificationState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        isRunning = false

        val selectedNodeName = currentNodeName

        if (configDir == null || configPath == null || apiSecret.isBlank()) {
            val message = if (apiSecret.isBlank()) {
                "VPN 凭据不可用，请打开应用重新连接"
            } else {
                "VPN 配置不可用，请打开应用重新连接"
            }
            Log.e(TAG, message)
            consumeStartResult(requestId, false, message)
            serviceStartInProgress.set(false)
            stopAfterStartFailure(recoveryAttempt)
            return START_NOT_STICKY
        }

        val startThread = Thread({
            try {
                startCoreWithVpn(
                    configDir,
                    configPath,
                    apiPort,
                    apiSecret,
                    selectedNodeName,
                    startToken,
                    requestId,
                    recoveryAttempt
                )
            } finally {
                serviceStartInProgress.set(false)
                if (serviceStartThread === Thread.currentThread()) {
                    serviceStartThread = null
                }
            }
        }, "SSRVPN-start").apply {
            isDaemon = true
        }
        serviceStartThread = startThread
        startThread.start()

        return START_STICKY
    }

    private fun currentNotificationState(): VpnNotificationState {
        val traffic = trafficTracker.snapshot()
        return VpnNotificationState(
            currentNodeName,
            notificationConnected,
            notificationStatusText,
            traffic.uploadRate,
            traffic.downloadRate,
            traffic.sessionUpload,
            traffic.sessionDownload,
            connectionStartedAt
        )
    }

    private fun buildDynamicNotification(
        state: VpnNotificationState = currentNotificationState()
    ): Notification =
        VpnNotificationSupport.buildStatusNotification(
            this,
            CHANNEL_ID,
            ACTION_DISCONNECT,
            state
        )

    internal fun updateNotificationNode(nodeName: String, expectedSessionGeneration: Long): Boolean {
        val updated = nativeSessionCommitter.updateNode(nodeName, expectedSessionGeneration)
        if (updated) notifyCurrentState()
        return updated
    }

    internal fun commitConnectionSnapshot(
        expectedSessionGeneration: Long,
        snapshot: NativeConnectionSnapshot
    ): String? {
        val generation =
            nativeSessionCommitter.commitSnapshot(expectedSessionGeneration, snapshot)
        if (generation != null && snapshot.selectedNodeName != null) notifyCurrentState()
        return generation
    }

    private fun notifyCurrentState(
        capturedState: VpnNotificationState? = null,
        allowPublication: (() -> Boolean)? = null
    ) {
        val state = capturedState ?: currentNotificationState()
        notificationGeneration.publishLatest(
            notificationHandler,
            state,
            { isRunning },
            allowPublication
        ) {
            notificationUpdatePolicy.publishIfChanged(it) {
                getSystemService(NotificationManager::class.java)
                    .notify(NOTIFICATION_ID, buildDynamicNotification(it))
            }
        }
    }

    private fun startNotificationUpdates() {
        notificationStatusText = null
        notificationConnected = true
        notificationHandler.removeCallbacks(notificationUpdater)
        notificationUpdatePolicy.onScreenStateChanged(isScreenInteractive())
        notificationHandler.post {
            notifyCurrentState()
            if (notificationUpdatePolicy.shouldScheduleTrafficRefresh()) {
                notificationHandler.postDelayed(
                    notificationUpdater,
                    notificationUpdatePolicy.initialRefreshDelayMillis
                )
            }
        }
    }

    private fun stopNotificationUpdates() {
        notificationHandler.removeCallbacks(notificationUpdater)
        notificationConnected = false
    }

    private fun isScreenInteractive(): Boolean =
        (getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive

    private fun startCoreWithVpn(
        configDir: String,
        configPath: String,
        apiPort: Int,
        apiSecret: String,
        selectedNodeName: String?,
        startToken: Long,
        requestId: String?,
        recoveryAttempt: Int
    ) {
        val packageName = packageName
        try {
            ensureStartCurrent(startToken)
            // Step 1: Initialize protect pipe
            Log.d(TAG, "Initializing protect pipe...")
            val protectReadFd = bridge.Bridge.initProtect()
            Log.d(TAG, "Protect pipe fd=$protectReadFd")

            // Step 2: Start protect monitor thread (reads fd, calls protect, sends result)
            protectThread = VpnProtectMonitor.start(
                protectReadFd,
                protectSocket = { socketFd -> protect(socketFd) },
                reportResult = { protected -> bridge.Bridge.setProtectResult(protected) }
            )
            if (protectThread != null) {
                Log.d(TAG, "Protect monitor started")
            }

            // Step 3: Establish VPN
            ensureStartCurrent(startToken)
            Log.d(TAG, "Establishing VPN...")
            val builder = Builder()
            builder.setSession("SSRVPN")
            // IPv4 公网路由保留局域网直连；IPv6 全量进入 VPN，避免泄漏。
            VpnRouteInstaller.configure(builder)
            builder.addDnsServer("223.5.5.5")
            builder.addDnsServer("8.8.8.8")
            builder.setMtu(1500)
            builder.setBlocking(true)
            // 排除自身避免 VPN 回环
            builder.addDisallowedApplication(packageName)
            // 排除无线调试服务，保持 adb 不被 VPN 劫持
            try { builder.addDisallowedApplication("com.android.adb") } catch (_: Exception) {}
            try { builder.addDisallowedApplication("com.google.android.adb") } catch (_: Exception) {}

            vpnFd = builder.establish()
            if (vpnFd == null) {
                Log.e(TAG, "VPN establish returned null!")
                consumeStartResult(requestId, false, "VPN establish failed")
                stopAfterStartFailure(recoveryAttempt)
                return
            }

            ensureStartCurrent(startToken)
            val tunFd = vpnFd!!.detachFd().toLong()
            Log.d(TAG, "VPN established! fd=$tunFd")

            if (tunFd <= 0) {
                Log.e(TAG, "Invalid VPN fd")
                consumeStartResult(requestId, false, "Invalid VPN fd")
                stopAfterStartFailure(recoveryAttempt)
                return
            }

            // Step 4: Initialize and start Mihomo
            ensureStartCurrent(startToken)
            Log.d(TAG, "Initializing Mihomo...")
            val startErr = startBridgeWithTimeout(configDir, configPath, tunFd)
            if (startErr == null) {
                Log.e(TAG, "Mihomo start timed out")
                consumeStartResult(requestId, false, "设备性能不足，请重新连接")
                stopAfterStartFailure(recoveryAttempt)
                return
            }
            if (startErr.isNotEmpty()) {
                Log.e(TAG, "Mihomo start failed: $startErr")
                consumeStartResult(requestId, false, "Mihomo: $startErr")
                stopAfterStartFailure(recoveryAttempt)
                return
            }
            ensureStartCurrent(startToken)
            Log.d(TAG, "Mihomo started with TUN fd=$tunFd")

            // Step 5: Wait for API health (use dynamic port)
            Log.d(TAG, "Waiting for API on port $apiPort...")
            val healthDeadlineNanos =
                System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(API_HEALTH_TIMEOUT_MS)
            val healthy = mihomoApiWaiter.waitUntilHealthy(
                apiPort,
                apiSecret,
                healthDeadlineNanos,
                API_HEALTH_POLL_INTERVAL_MS,
                ensureCurrent = { ensureStartCurrent(startToken) }
            )
            if (healthy) Log.d(TAG, "Mihomo API /version is healthy")

            if (healthy) {
                ensureStartCurrent(startToken)
                Log.d(TAG, "Core started!")
                applyProxySelection(apiPort, apiSecret, selectedNodeName)
                val published = startGeneration.runIfCurrent(startToken) {
                    NativeConnectionSession.publishRunning(configPath)
                    isRunning = true
                    broadcastState(this)
                    startNotificationUpdates()
                    consumeStartResult(
                        requestId,
                        true,
                        "OK",
                        NativeConnectionSession.snapshot(true, startToken)
                    )
                    serviceStartInProgress.set(false)
                }
                if (!published) throw StartCancelledException()

                Thread({
                    monitorCoreRunning(
                        startToken,
                        CoreRecoveryRequest(
                            configDir,
                            configPath,
                            apiPort,
                            apiSecret,
                            recoveryAttempt
                        )
                    )
                }, "SSRVPN-core-monitor").apply {
                    isDaemon = true
                    start()
                }
            } else {
                Log.e(TAG, "Health check timeout")
                consumeStartResult(requestId, false, "设备性能不足，请重新连接")
                stopAfterStartFailure(recoveryAttempt)
            }
        } catch (e: StartCancelledException) {
            Log.d(TAG, "VPN start cancelled")
            consumeStartResult(requestId, false, "连接已取消")
            stopAll()
        } catch (e: Exception) {
            Log.e(TAG, "startCoreWithVpn error", e)
            consumeStartResult(requestId, false, "Error: ${e.message}")
            stopAfterStartFailure(recoveryAttempt)
        }
    }

    private fun ensureStartCurrent(startToken: Long) {
        if (startToken != startGeneration.current() ||
            stopOperation.isRunning ||
            processTerminationPending.get()
        ) {
            throw StartCancelledException()
        }
    }

    private fun startBridgeWithTimeout(
        configDir: String,
        configPath: String,
        tunFd: Long
    ): String? {
        if (!bridgeStartInProgress.compareAndSet(false, true)) {
            Log.w(TAG, "Bridge.start already in progress")
            return "核心正在启动，请稍后重试"
        }
        var result: String? = null
        var error: Exception? = null
        val bridgeThread = Thread({
            try {
                bridge.Bridge.init(configDir, "config.yaml")
                result = bridge.Bridge.start(configPath, tunFd)
                Log.d(TAG, "Bridge.start returned")
            } catch (e: Exception) {
                error = e
            } finally {
                bridgeStartInProgress.set(false)
            }
        }, "SSRVPN-bridge-start").apply {
            isDaemon = true
            start()
        }
        try {
            bridgeThread.join(BRIDGE_START_TIMEOUT_MS)
            if (bridgeThread.isAlive) {
                Log.e(TAG, "Bridge.start timed out after ${BRIDGE_START_TIMEOUT_MS}ms")
                return null
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            Log.e(TAG, "Interrupted while waiting for Bridge.start", e)
            return "启动被中断"
        }
        error?.let { throw it }
        return result ?: ""
    }

    private fun monitorCoreRunning(
        startToken: Long,
        request: CoreRecoveryRequest
    ) {
        try {
            // 核心意外退出：必须关闭 VPN 接口并停止前台服务，
            // 否则全局流量仍被路由进无人读取的 TUN，导致整机断网
            if (CoreLivenessMonitor.waitForUnexpectedExit(
                    startToken,
                    startGeneration::current,
                    { isRunning },
                    ::isBridgeRunningWithTimeout
                )
            ) {
                Log.e(TAG, "Mihomo stopped unexpectedly")
                recoverFromUnexpectedCoreExit(request)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Monitor error", e)
            stopAll {
                try {
                    showCoreRecoveryFailedNotification()
                } catch (notificationError: Exception) {
                    Log.e(TAG, "Unable to show core recovery failure", notificationError)
                }
            }
        }
    }

    private fun recoverFromUnexpectedCoreExit(request: CoreRecoveryRequest) {
        val nextAttempt = CoreRecoveryPolicy.nextAttempt(request.attempt)
        if (nextAttempt == null) {
            Log.e(TAG, "Core recovery limit reached")
            stopAll { showCoreRecoveryFailedNotification() }
            return
        }
        if (manualStopRequested.get()) return

        val recoveryToken = recoveryGeneration.incrementAndGet()
        if (!NativeVpnSessionCoordinator.reserveRecovery(request.configPath)) return
        notificationStatusText = CoreRecoveryPolicy.recoveringMessage(nextAttempt)
        notificationConnected = false
        notifyCurrentState(currentNotificationState()) {
            CoreRecoveryPolicy.shouldPublishRecovery(
                recoveryToken,
                recoveryGeneration.get(),
                manualStopRequested.get(),
                processTerminationPending.get()
            )
        }

        stopForRecovery {
            if (manualStopRequested.get() ||
                recoveryToken != recoveryGeneration.get() ||
                processTerminationPending.get()
            ) {
                if (processTerminationPending.get()) {
                    showCoreRecoveryFailedNotification()
                }
                return@stopForRecovery
            }
            try {
                val restartIntent = createStartIntent(
                    this,
                    request.configDir,
                    request.configPath,
                    request.apiPort,
                    request.apiSecret,
                    currentNodeName,
                    recoveryAttempt = nextAttempt,
                    recoveryToken = recoveryToken
                )
                ContextCompat.startForegroundService(this, restartIntent)
            } catch (e: Exception) {
                Log.e(TAG, "Unable to restart VPN core", e)
                NativeVpnSessionCoordinator.clearRecovery()
                showCoreRecoveryFailedNotification()
                stopSelf()
            }
        }
    }

    private fun stopAfterStartFailure(recoveryAttempt: Int) =
        if (recoveryAttempt > 0) stopAll { showCoreRecoveryFailedNotification() } else stopAll()

    private fun showCoreRecoveryFailedNotification() =
        getSystemService(NotificationManager::class.java).notify(
            RECOVERY_FAILURE_NOTIFICATION_ID,
            VpnNotificationSupport.buildRecoveryFailureNotification(this, CHANNEL_ID)
        )

    private fun isBridgeRunningWithTimeout(): Boolean {
        if (!bridgeRunningCheckInProgress.compareAndSet(false, true)) {
            Log.w(TAG, "Bridge.isRunning already in progress; deferring verdict")
            return true
        }
        var result = false
        var error: Exception? = null
        val bridgeThread = Thread({
            try {
                result = bridge.Bridge.isRunning()
            } catch (e: Exception) {
                error = e
                result = false
            } finally {
                bridgeRunningCheckInProgress.set(false)
            }
        }, "SSRVPN-bridge-is-running").apply {
            isDaemon = true
            start()
        }
        try {
            bridgeThread.join(BRIDGE_IS_RUNNING_TIMEOUT_MS)
            if (bridgeThread.isAlive) {
                Log.e(TAG, "Bridge.isRunning timed out after ${BRIDGE_IS_RUNNING_TIMEOUT_MS}ms; treating as stopped")
                return false
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            Log.e(TAG, "Interrupted while waiting for Bridge.isRunning", e)
            return false
        }
        error?.let { Log.e(TAG, "Bridge.isRunning error", it) }
        return result
    }

    private fun applyProxySelection(apiPort: Int, apiSecret: String, nodeName: String?) =
        MihomoProxySelection.apply(apiPort, apiSecret, nodeName)

    fun stopAll(onComplete: (() -> Unit)? = null) {
        manualStopRequested.set(true)
        recoveryGeneration.incrementAndGet()
        stopInternal(stopServiceWhenDone = true, onComplete = onComplete)
    }

    private fun stopForRecovery(onComplete: () -> Unit) =
        stopInternal(stopServiceWhenDone = false, onComplete = onComplete)

    private fun stopInternal(
        stopServiceWhenDone: Boolean,
        onComplete: (() -> Unit)?
    ) {
        notificationGeneration.invalidate()
        startGeneration.invalidate {
            NativeConnectionSession.beginStopping()
            isRunning = false
            if (manualStopRequested.get()) {
                NativeConnectionSession.clearRecovery()
                NativeConnectionSession.clearStarting()
            }
        }
        serviceStartThread?.interrupt()
        val completion: () -> Unit = {
            if (stopServiceWhenDone || manualStopRequested.get()) {
                stopSelf()
            }
            onComplete?.invoke()
            Unit
        }
        if (!stopOperation.joinOrBegin(completion)) {
            Log.d(TAG, "Stop already in progress")
            return
        }
        Thread({
            var terminateProcess = false
            try {
                terminateProcess = stopAllOnWorker()
            } finally {
                if (terminateProcess) processTerminationPending.set(true)
                stopOperation.complete()
            }
            if (terminateProcess) {
                Log.e(
                    TAG,
                    "Bridge.stop failed or timed out; terminating process to release the detached TUN fd"
                )
                notificationHandler.postDelayed({
                    android.os.Process.killProcess(android.os.Process.myPid())
                }, 750L)
            }
        }, "SSRVPN-stop").apply {
            isDaemon = true
            start()
        }
    }

    private fun stopAllOnWorker(): Boolean {
        Log.d(TAG, "Stopping...")
        stopNotificationUpdates()
        protectThread?.interrupt()
        protectThread = null
        val pendingStartStopped = waitForPendingStart()
        val bridgeStopped = pendingStartStopped && stopBridgeWithTimeout()
        try {
            vpnFd?.close()
        } catch (_: Exception) {}
        vpnFd = null
        isRunning = false
        if (bridgeStopped) NativeConnectionSession.clearRunning()
        broadcastState(this)
        try {
            // 修复: 使用兼容 Android 13+ 的方式停止前台服务
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (e: Exception) {
            Log.w(TAG, "stopForeground failed: ${e.message}")
        }
        Log.d(TAG, "Stopped")
        return !bridgeStopped
    }

    private fun waitForPendingStart(): Boolean {
        val deadline = SystemClock.elapsedRealtime() + PENDING_START_CANCEL_GRACE_MS
        serviceStartThread?.interrupt()
        while (SystemClock.elapsedRealtime() < deadline) {
            val thread = serviceStartThread
            if ((thread == null || !thread.isAlive) && !bridgeStartInProgress.get()) {
                return true
            }
            try {
                thread?.join(100L)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        Log.e(
            TAG,
            "Pending VPN start did not stop within ${PENDING_START_CANCEL_GRACE_MS}ms; " +
                "forcing process cleanup"
        )
        return false
    }

    private fun stopBridgeWithTimeout(): Boolean {
        if (!bridgeStopInProgress.compareAndSet(false, true)) {
            Log.w(TAG, "Bridge.stop already in progress; skipping duplicate stop")
            return false
        }
        val bridgeStopSucceeded = AtomicBoolean(false)
        val bridgeThread = Thread({
            try {
                bridge.Bridge.stop()
                bridgeStopSucceeded.set(true)
                Log.d(TAG, "Bridge.stop returned")
            } catch (e: Exception) {
                Log.e(TAG, "Bridge stop error", e)
            } finally {
                bridgeStopInProgress.set(false)
            }
        }, "SSRVPN-bridge-stop").apply {
            isDaemon = true
            start()
        }
        try {
            bridgeThread.join(BRIDGE_STOP_TIMEOUT_MS)
            if (bridgeThread.isAlive) {
                Log.e(TAG, "Bridge.stop timed out after ${BRIDGE_STOP_TIMEOUT_MS}ms; continuing VPN cleanup")
                return false
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            Log.e(TAG, "Interrupted while waiting for Bridge.stop", e)
            return false
        }
        return bridgeStopSucceeded.get()
    }

    override fun onDestroy() {
        super.onDestroy()
        try { unregisterReceiver(disconnectReceiver) } catch (_: Exception) {}
        try { unregisterReceiver(screenStateReceiver) } catch (_: Exception) {}
        stopAll()
        instance = null
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
