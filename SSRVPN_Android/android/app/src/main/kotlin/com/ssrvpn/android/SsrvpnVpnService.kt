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

private class StartCancelledException : Exception("VPN start cancelled")

class SsrvpnVpnService : VpnService() {
    companion object {
        private const val TAG = "SsrvpnVpn"
        private const val CHANNEL_ID = "ssrvpn_vpn"
        private const val NOTIFICATION_ID = 1
        private const val RECOVERY_FAILURE_NOTIFICATION_ID = 2
        const val ACTION_DISCONNECT = "com.ssrvpn.ACTION_DISCONNECT"
        const val ACTION_CONNECT = "com.ssrvpn.ACTION_CONNECT"
        private const val EXTRA_REQUEST_ID = "com.ssrvpn.extra.REQUEST_ID"
        internal const val EXTRA_START_PAYLOAD_ID = "com.ssrvpn.extra.START_PAYLOAD_ID"
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
            requestId: String? = null,
            startPayloadId: String? = null,
            startClaimId: String? = null,
            recoveryAttempt: Int = 0,
            recoveryToken: Long? = null
        ): Intent = Intent(context, SsrvpnVpnService::class.java).apply {
            putExtra(EXTRA_REQUEST_ID, requestId)
            startPayloadId?.let { putExtra(EXTRA_START_PAYLOAD_ID, it) }
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

        private const val BRIDGE_STOP_TIMEOUT_MS = 5_000L
        private const val BRIDGE_IS_RUNNING_TIMEOUT_MS = 2_000L
        private const val PROTECT_MONITOR_STOP_TIMEOUT_MS = 1_000L
        private val stopOperation = CoalescedOperation()
        private val serviceStartInProgress = AtomicBoolean(false)
        private val bridgeStartInProgress = AtomicBoolean(false)
        private val bridgeStopInProgress = AtomicBoolean(false)
        private val bridgeRunningCheckInProgress = AtomicBoolean(false)
        private val bridgeFdTerminationRequired = AtomicBoolean(false)
        private val processTerminationPending = AtomicBoolean(false)
        internal val startGeneration = StartGenerationGate()
        private val manualStopRequested = AtomicBoolean(false)

        fun isCoreOperationBusy(): Boolean =
            stopOperation.isRunning ||
                serviceStartInProgress.get() ||
                bridgeStartInProgress.get() ||
                bridgeStopInProgress.get() ||
                processTerminationPending.get()

        fun cancelPendingStart() {
            startGeneration.invalidate { isRunning = false }
            instance?.stopAll(recordManualStop = true)
        }
        internal fun underlyingNetworkSnapshot(): UnderlyingNetworkSnapshot? =
            instance?.underlyingNetworkMonitor?.snapshot()
    }
    private var vpnFd: ParcelFileDescriptor? = null
    private var protectMonitor: VpnProtectMonitor.Monitor? = null
    @Volatile
    private var serviceStartThread: Thread? = null
    private val serviceStopGate = VpnServiceStopGate()
    private val notificationHandler = Handler(Looper.getMainLooper())
    private var currentNodeName = "SSRVPN"
    private var currentApiPort = 0
    private var currentDataPorts = listOf(7890, 7891)
    private val runtimeDiagnostics = NativeRuntimeDiagnosticsTracker()
    private var underlyingNetworkMonitor: UnderlyingNetworkMonitor? = null
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
        AndroidRuntimeGuard.run(TAG, "Unable to initialize VPN notification channel") {
            VpnNotificationSupport.createChannel(this, CHANNEL_ID)
        }
        AndroidRuntimeGuard.run(TAG, "Unable to register VPN service receivers") {
            ContextCompat.registerReceiver(
                this,
                screenStateReceiver,
                IntentFilter().apply {
                    addAction(Intent.ACTION_SCREEN_OFF)
                    addAction(Intent.ACTION_SCREEN_ON)
                },
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
        }
        AndroidRuntimeGuard.run(TAG, "Unable to read initial screen state") {
            notificationUpdatePolicy.onScreenStateChanged(isScreenInteractive())
        }
        AndroidRuntimeGuard.run(TAG, "Unable to observe underlying network state") {
            underlyingNetworkMonitor = UnderlyingNetworkMonitor(this) {
                if (isRunning) {
                    notifyCurrentState()
                    broadcastState(this)
                }
            }.also(UnderlyingNetworkMonitor::start)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "VPN Service starting...")
        if (intent?.action == ACTION_DISCONNECT) {
            serviceStopGate.acceptStart(startId)
            Log.d(TAG, "Received disconnect from notification")
            stopAll(recordManualStop = true)
            return START_NOT_STICKY
        }
        if (intent == null && !VpnServiceRestartStore.shouldAcceptStickyRestart(this)) {
            Log.i(TAG, "Ignoring sticky VPN restart after a persisted manual disconnect")
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        val requestId = intent?.getStringExtra(EXTRA_REQUEST_ID)
        val startPayloadId = intent?.getStringExtra(EXTRA_START_PAYLOAD_ID)
        val startPayload = NativeStartPayloadRegistry.consume(startPayloadId)
        val startClaimId = intent?.getStringExtra(EXTRA_START_CLAIM_ID)
        val recoveryAttempt = intent?.getIntExtra(EXTRA_RECOVERY_ATTEMPT, 0) ?: 0
        val recoveryToken = if (intent?.hasExtra(EXTRA_RECOVERY_TOKEN) == true) {
            intent.getLongExtra(EXTRA_RECOVERY_TOKEN, -1L)
        } else {
            null
        }

        if (recoveryAttempt > 0 && !CoreRecoveryCoordinator.shouldAcceptRestart(
                this,
                recoveryAttempt,
                recoveryToken
            )
        ) {
            Log.w(TAG, "Ignoring obsolete VPN recovery request")
            NativeVpnSessionCoordinator.releasePendingStart(startClaimId)
            consumeStartResult(requestId, false, "自动恢复请求已失效")
            return finishRejectedServiceStart(
                startId, isRunning, serviceStartInProgress.get())
        }
        if (intent != null && !VpnServiceRestartStore.recordExplicitStart(this)) {
            Log.e(TAG, "Unable to persist explicit VPN connection intent")
        }

        if (isRunning) {
            serviceStopGate.acceptStart(startId)
            Log.d(TAG, "VPN is already running; reusing the active session")
            NativeVpnSessionCoordinator.releasePendingStart(startClaimId)
            consumeStartResult(requestId, true, "Already running",
                NativeVpnSessionCoordinator.connectionState())
            return START_STICKY
        }
        if (stopOperation.isRunning || processTerminationPending.get()) {
            serviceStopGate.includeRejectedStart(startId)
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
            return finishRejectedServiceStart(startId, isRunning, false)
        }
        serviceStopGate.acceptStart(startId)

        val snapshot = if (startPayloadId == null) {
            NativeConnectionSnapshotStore.read(this)
        } else {
            startPayload
        }
        val configDir = snapshot?.configDir
        val configPath = snapshot?.configPath
        val apiPort = snapshot?.apiPort ?: 9090
        val apiSecret = snapshot?.apiSecret.orEmpty()
        currentApiPort = apiPort
        currentDataPorts = CoreDataPorts.fromPreferences(
            getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE).all
        )
        configPath?.let(NativeConnectionSession::reserveStarting)

        currentNodeName = snapshot?.selectedNodeName
            ?: "SSRVPN"
        connectionStartedAt = System.currentTimeMillis()
        notificationConnected = false
        notificationStatusText = if (recoveryAttempt > 0) {
            CoreRecoveryPolicy.recoveringMessage(recoveryAttempt)
        } else {
            null
        }
        trafficTracker.reset()

        AndroidRuntimeGuard.run(TAG, "Unable to clear stale recovery notification") {
            getSystemService(NotificationManager::class.java)
                .cancel(RECOVERY_FAILURE_NOTIFICATION_ID)
        }
        val foregroundStarted = AndroidRuntimeGuard.run(
            TAG,
            "Unable to enter VPN foreground mode"
        ) {
            notificationUpdatePolicy.resetPublishedState()
            val initialNotificationState = currentNotificationState()
            val notification = buildDynamicNotification(initialNotificationState)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            notificationUpdatePolicy.markPublished(initialNotificationState)
        }
        if (!foregroundStarted) {
            consumeStartResult(requestId, false, "无法启动 Android 前台 VPN 服务")
            serviceStartInProgress.set(false)
            stopAfterStartFailure(recoveryAttempt)
            return START_NOT_STICKY
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
            notificationStatusText ?: underlyingNetworkMonitor?.statusText(),
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
            AndroidRuntimeGuard.run(TAG, "Unable to publish VPN notification") {
                notificationUpdatePolicy.publishIfChanged(it) {
                    getSystemService(NotificationManager::class.java)
                        .notify(NOTIFICATION_ID, buildDynamicNotification(it))
                }
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
        try {
            ensureStartCurrent(startToken)
            Log.d(TAG, "Establishing VPN...")
            val builder = Builder()
            builder.setSession("SSRVPN")
            // IPv4 公网路由保留局域网直连；IPv6 全量进入 VPN，避免泄漏。
            VpnRouteInstaller.configure(builder)
            builder.setMtu(1500)
            // Keep Android's documented default non-blocking TUN contract.
            builder.setBlocking(false)
            // Keep this app inside TUN; protect Mihomo outbound sockets individually.
            val bypassedDomesticApps = VpnAppExclusionInstaller.install(builder)
            Log.i(TAG, "Bypassing ${bypassedDomesticApps.size} installed domestic apps")

            runtimeDiagnostics.beginTunLease()
            vpnFd = builder.establish()
            if (vpnFd == null) {
                Log.e(TAG, "VPN establish returned null!")
                return rejectCoreStart(
                    requestId,
                    "系统未能创建 VPN 接口，请检查 VPN 权限后重试",
                    recoveryAttempt
                )
            }

            ensureStartCurrent(startToken)
            Log.d(TAG, "Initializing protect pipe...")
            val protectReadFd = bridge.Bridge.initProtect()
            Log.d(TAG, "Protect pipe fd=$protectReadFd")
            protectMonitor = VpnProtectMonitor.start(
                protectReadFd,
                protectSocket = { socketFd -> protect(socketFd) },
                reportResult = { protected -> bridge.Bridge.setProtectResult(protected) }
            )
            if (!VpnRuntimeHealth.hasProtectMonitor(protectMonitor?.thread)) {
                return rejectCoreStart(requestId, "VPN 网络保护服务启动失败，请重新连接", recoveryAttempt)
            }
            Log.d(TAG, "Protect monitor started")

            ensureStartCurrent(startToken)
            val descriptor = checkNotNull(vpnFd)
            val bridgeDescriptor = ParcelFileDescriptor.dup(descriptor.fileDescriptor)
            val tunFdOwner = DetachedTunFdOwner.detach(bridgeDescriptor)
            val tunFd = tunFdOwner.descriptorNumber
            runtimeDiagnostics.claimTunDescriptor(tunFd)
            Log.d(TAG, "VPN established! fd=$tunFd")
            try {
                ensureStartCurrent(startToken)
                Log.d(TAG, "Initializing Mihomo...")
                val startErr = startBridgeWithTimeout(configDir, configPath, tunFdOwner)
                if (startErr == null) {
                    Log.e(TAG, "Mihomo start timed out")
                    return rejectCoreStart(requestId, "VPN 核心启动超时，请重新连接", recoveryAttempt)
                }
                if (startErr.isNotEmpty()) {
                    Log.e(TAG, "Mihomo start failed: $startErr")
                    return rejectCoreStart(
                        requestId,
                        "VPN 核心启动失败，请重试；若持续失败请打开诊断与运行日志",
                        recoveryAttempt
                    )
                }
                ensureStartCurrent(startToken)
                Log.d(TAG, "Mihomo started with TUN fd=$tunFd")
                Log.d(TAG, "Waiting for API on port $apiPort...")
                val healthDeadlineNanos =
                    System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(VpnStartBudget.API_HEALTH_MS)
                val healthy = mihomoApiWaiter.waitUntilHealthy(
                    apiPort,
                    apiSecret,
                    healthDeadlineNanos,
                    VpnStartBudget.API_POLL_MS,
                    ensureCurrent = { ensureStartCurrent(startToken) }
                )
                if (healthy) Log.d(TAG, "Mihomo API /version is healthy")

                if (healthy && !VpnRuntimeHealth.hasProtectMonitor(protectMonitor?.thread)) {
                    return rejectCoreStart(
                        requestId,
                        "VPN 网络保护服务异常，请重新连接",
                        recoveryAttempt
                    )
                }

                if (healthy) {
                    ensureStartCurrent(startToken)
                    Log.d(TAG, "Core started!")
                    applyProxySelection(apiPort, apiSecret, selectedNodeName)
                    val dataPlaneFailure =
                        VpnDataPlaneProbe.startupOutcome(protectMonitor?.thread) {
                            ensureStartCurrent(startToken)
                        }.failureMessage
                    if (dataPlaneFailure != null) {
                        return rejectCoreStart(requestId, dataPlaneFailure, recoveryAttempt)
                    }
                    ensureStartCurrent(startToken)
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
                    rejectCoreStart(
                        requestId,
                        "VPN 核心已启动，但本地控制服务未及时就绪，请重新连接",
                        recoveryAttempt
                    )
                }
            } finally {
                tunFdOwner.close()
            }
        } catch (e: StartCancelledException) {
            Log.d(TAG, "VPN start cancelled")
            consumeStartResult(requestId, false, "连接已取消")
            stopAll()
        } catch (e: LinkageError) {
            Log.e(TAG, "VPN native bridge linkage failed", e)
            rejectCoreStart(requestId, "Mihomo 原生组件不可用，请重新安装应用", recoveryAttempt)
        } catch (e: Exception) {
            Log.e(TAG, "startCoreWithVpn error", e)
            rejectCoreStart(
                requestId,
                "VPN 启动失败，请重试；若持续失败请打开诊断与运行日志",
                recoveryAttempt
            )
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
        configDir: String, configPath: String, tunFdOwner: DetachedTunFdOwner
    ): String? {
        if (!bridgeStartInProgress.compareAndSet(false, true)) {
            Log.w(TAG, "Bridge.start already in progress")
            return "核心正在启动，请稍后重试"
        }
        var result: String? = null
        var error: Throwable? = null
        val bridgeThread = Thread({
            try {
                result = tunFdOwner.startWithBridge(
                    { bridge.Bridge.init(configDir, "config.yaml") },
                    { bridgeFdTerminationRequired.set(true) }
                ) { tunFd -> bridge.Bridge.start(configPath, tunFd) }
                Log.d(TAG, "Bridge.start returned")
            } catch (e: Throwable) {
                error = e
            } finally {
                bridgeStartInProgress.set(false)
            }
        }, "SSRVPN-bridge-start").apply {
            isDaemon = true
            start()
        }
        try {
            bridgeThread.join(VpnStartBudget.BRIDGE_MS)
            if (bridgeThread.isAlive) {
                Log.e(TAG, "Bridge.start timed out after ${VpnStartBudget.BRIDGE_MS}ms")
                return null
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            Log.e(TAG, "Interrupted while waiting for Bridge.start", e)
            return "启动被中断"
        }
        error?.let { throw it.asBridgeStartException() }
        return result ?: ""
    }

    private fun monitorCoreRunning(
        startToken: Long,
        request: CoreRecoveryRequest
    ) {
        try {
            // 核心意外退出：必须关闭 VPN 接口并停止前台服务，
            // 否则全局流量仍被路由进无人读取的 TUN，导致整机断网
            val liveness = CoreLivenessMonitor.waitForUnexpectedExit(
                startToken = startToken,
                currentGeneration = startGeneration::current,
                isRunning = { isRunning },
                recoveryAttempt = request.attempt,
                isBridgeRunning = ::isBridgeRunningWithTimeout,
                isProtectMonitorRunning = {
                    VpnRuntimeHealth.hasProtectMonitor(protectMonitor?.thread)
                },
                isApiHealthy = { VpnRuntimeHealth.isApiHealthy(request.apiPort, request.apiSecret) },
                isApiPortReachable = { CorePortReleaseVerifier.isPortListening(request.apiPort) }
            )
            if (liveness.unexpectedExit) {
                Log.e(TAG, "Mihomo stopped unexpectedly")
                CoreRecoveryCoordinator.recoverFromUnexpectedCoreExit(
                    this,
                    request.copy(attempt = liveness.recoveryAttempt)
                )
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

    internal fun publishCoreRecovery(
        attempt: Int,
        allowPublication: () -> Boolean
    ) {
        notificationStatusText = CoreRecoveryPolicy.recoveringMessage(attempt)
        notificationConnected = false
        notifyCurrentState(currentNotificationState(), allowPublication)
    }

    internal fun hasManualStopRequest(): Boolean = manualStopRequested.get()

    internal fun hasPendingProcessTermination(): Boolean = processTerminationPending.get()

    private fun stopAfterStartFailure(recoveryAttempt: Int) =
        CoreRecoveryCoordinator.stopAfterStartFailure(
            this,
            notificationHandler,
            recoveryAttempt
        )

    private fun rejectCoreStart(requestId: String?, message: String, recoveryAttempt: Int) =
        consumeStartResult(requestId, false, message).also { stopAfterStartFailure(recoveryAttempt) }

    internal fun showCoreRecoveryFailedNotification() {
        AndroidRuntimeGuard.run(TAG, "Unable to show core recovery failure") {
            getSystemService(NotificationManager::class.java).notify(
                RECOVERY_FAILURE_NOTIFICATION_ID,
                VpnNotificationSupport.buildRecoveryFailureNotification(this, CHANNEL_ID)
            )
        }
    }

    private fun isBridgeRunningWithTimeout(): Boolean? {
        if (!bridgeRunningCheckInProgress.compareAndSet(false, true)) {
            Log.w(TAG, "Bridge.isRunning already in progress; deferring verdict")
            return null
        }
        var result: Boolean? = null
        val bridgeThread = Thread({
            try {
                result = bridge.Bridge.isRunning()
            } catch (e: LinkageError) {
                Log.e(TAG, "Bridge.isRunning linkage error", e)
            } catch (e: Exception) {
                Log.e(TAG, "Bridge.isRunning error", e)
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
                Log.e(TAG, "Bridge.isRunning timed out after ${BRIDGE_IS_RUNNING_TIMEOUT_MS}ms; treating stop as unverified")
                return null
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            Log.e(TAG, "Interrupted while waiting for Bridge.isRunning", e)
            return null
        }
        return result
    }
    internal fun runtimeDiagnosticsSnapshot(): NativeRuntimeDiagnostics =
        runtimeDiagnostics.snapshot(
            isRunning, isCoreOperationBusy(),
            VpnRuntimeHealth.hasProtectMonitor(protectMonitor?.thread),
            isBridgeRunningWithTimeout()
        )
    private fun applyProxySelection(apiPort: Int, apiSecret: String, nodeName: String?) =
        MihomoProxySelection.apply(apiPort, apiSecret, nodeName)
    fun stopAll(
        preserveForegroundUi: Boolean = false,
        recordManualStop: Boolean = false,
        onComplete: ((Boolean) -> Unit)? = null
    ) {
        if (recordManualStop && !VpnServiceRestartStore.recordManualStop(this)) {
            Log.e(TAG, "Unable to persist manual VPN disconnect")
        }
        manualStopRequested.set(true)
        CoreRecoveryCoordinator.cancelPendingRecovery()
        stopInternal(true, preserveForegroundUi, onComplete)
    }
    internal fun stopForRecovery(onComplete: () -> Unit) =
        stopInternal(false, true) { onComplete() }

    private fun stopInternal(
        stopServiceWhenDone: Boolean, preserveForegroundUi: Boolean,
        onComplete: ((Boolean) -> Unit)?
    ) {
        val stopToken = serviceStopGate.beginOrJoinStop()
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
        val completion: (Boolean) -> Unit = { stoppedCleanly ->
            val stopStartId = serviceStopGate.finishStop(stopToken)
            if ((stopServiceWhenDone || manualStopRequested.get()) &&
                stopStartId != null) {
                stopSelfResult(stopStartId)
            }
            onComplete?.invoke(stoppedCleanly)
            Unit
        }
        if (!stopOperation.joinOrBegin(completion)) {
            Log.d(TAG, "Stop already in progress")
            return
        }
        Thread({
            StopOperationRunner.run(
                bridgeFdTerminationRequired.get(),
                { stopAllOnWorker(removeForeground = !preserveForegroundUi) },
                {
                    processTerminationPending.set(true)
                    DisconnectRecoveryCoordinator.handoffIfNeeded(this, preserveForegroundUi)
                },
                stopOperation::complete,
                {
                    Log.e(TAG, "Core shutdown incomplete; terminating process to release the detached TUN fd")
                    notificationHandler.postDelayed({
                        android.os.Process.killProcess(android.os.Process.myPid())
                    }, 750L)
                }
            )?.let { Log.e(TAG, "Stop cleanup failed; process termination scheduled", it) }
        }, "SSRVPN-stop").apply {
            isDaemon = true
            start()
        }
    }

    private fun stopAllOnWorker(removeForeground: Boolean): Boolean {
        Log.d(TAG, "Stopping...")
        stopNotificationUpdates()
        val activeProtectMonitor = protectMonitor.also { it?.stop() }
        protectMonitor = null
        serviceStartThread?.interrupt()
        stopBridgeWithTimeout() // Cancel any Start already inside native code.
        val pendingStartStopped = waitForPendingStart()
        val bridgeStopped = stopBridgeWithTimeout() // Catch any later native Start.
        val retainedLease = vpnFd.also { vpnFd = null }
        val tunReleased = TunReleaseVerifier.releaseOwnedLeaseAndWait(
            bridgeStopped = bridgeStopped,
            closeOwnedLease = { runCatching { retainedLease?.close() } },
            isReleased = runtimeDiagnostics::releaseTunDescriptorIfClosed
        )
        if (bridgeStopped && !tunReleased)
            Log.e(TAG, "Bridge stopped but the owned TUN lease is still present")
        val protectMonitorStopped = waitForProtectMonitor(activeProtectMonitor?.thread)
        val stopDecision = CoreStopDecision.afterBridgeCheck(
            pendingStartStopped,
            bridgeStopped && protectMonitorStopped && tunReleased,
            currentDataPorts
        )
        if (stopDecision.terminateProcess) {
            Log.e(TAG, stopDecision.terminationMessage(currentDataPorts))
        }
        isRunning = false
        if (stopDecision.clearRunningSession) NativeConnectionSession.clearRunning()
        broadcastState(this)
        if (removeForeground) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
            } catch (e: Exception) {
                Log.w(TAG, "stopForeground failed: ${e.message}")
            }
        }
        Log.d(TAG, "Stopped")
        return bridgeFdTerminationRequired.get() || stopDecision.terminateProcess
    }

    private fun waitForProtectMonitor(thread: Thread?): Boolean {
        if (thread == null || !thread.isAlive) return true
        try {
            thread.join(PROTECT_MONITOR_STOP_TIMEOUT_MS)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            Log.e(TAG, "Interrupted while waiting for protect monitor", error)
            return false
        }
        if (!thread.isAlive) return true
        Log.e(
            TAG,
            "Protect monitor did not stop within " +
                "${PROTECT_MONITOR_STOP_TIMEOUT_MS}ms"
        )
        return false
    }

    private fun waitForPendingStart(): Boolean {
        val deadline = SystemClock.elapsedRealtime() + VpnStartBudget.CANCEL_GRACE_MS
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
            "Pending VPN start did not stop within ${VpnStartBudget.CANCEL_GRACE_MS}ms; " +
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
            } catch (e: LinkageError) {
                Log.e(TAG, "Bridge stop linkage error", e)
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
        return bridgeStopSucceeded.get() && isBridgeRunningWithTimeout() == false
    }

    override fun onDestroy() {
        super.onDestroy()
        underlyingNetworkMonitor?.stop()
        underlyingNetworkMonitor = null
        try { unregisterReceiver(screenStateReceiver) } catch (_: Exception) {}
        if (!processTerminationPending.get()) stopAll(recordManualStop = false)
        instance = null
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
