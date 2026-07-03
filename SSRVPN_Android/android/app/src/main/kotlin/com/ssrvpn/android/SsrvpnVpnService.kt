package com.ssrvpn.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.net.TrafficStats
import android.util.Log
import java.io.FileInputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import org.json.JSONObject

class SsrvpnVpnService : VpnService() {
    companion object {
        private const val TAG = "SsrvpnVpn"
        private const val CHANNEL_ID = "ssrvpn_vpn"
        private const val NOTIFICATION_ID = 1

        const val ACTION_DISCONNECT = "com.ssrvpn.ACTION_DISCONNECT"
        const val ACTION_CONNECT = "com.ssrvpn.ACTION_CONNECT"

        @Volatile
        var isRunning = false
            private set

        @Volatile
        var instance: SsrvpnVpnService? = null
            private set

        @Volatile
        var pendingConfigDir: String? = null
        @Volatile
        var pendingConfigPath: String? = null
        @Volatile
        var pendingApiPort: Int = 9090
        @Volatile
        var pendingApiSecret: String? = null
        @Volatile
        var pendingNodeName: String? = null

        // 一次性消费回调，避免持有 Activity 引用导致泄漏
        @Volatile
        private var _startResultCallback: ((Boolean, String) -> Unit)? = null

        fun setStartResultCallback(callback: ((Boolean, String) -> Unit)?) {
            _startResultCallback = callback
        }

        fun clearStartResultCallback(callback: ((Boolean, String) -> Unit)?) {
            if (callback == null || _startResultCallback === callback) {
                _startResultCallback = null
            }
        }

        fun completeStartResult(success: Boolean, message: String) {
            consumeStartResult(success, message)
        }

        /** 消费回调（一次性，调用后自动置空） */
        private fun consumeStartResult(success: Boolean, message: String) {
            val cb = _startResultCallback
            _startResultCallback = null
            cb?.invoke(success, message)
        }

        /** 广播 VPN 状态变更 */
        fun broadcastState(context: Context) {
            val intent = Intent(VpnTileService.ACTION_VPN_STATE_CHANGED)
            intent.putExtra(VpnTileService.EXTRA_CONNECTED, isRunning)
            // Android 14+ 隐式广播不会投递给 NOT_EXPORTED 接收器，必须显式指定包名
            intent.setPackage(context.packageName)
            context.sendBroadcast(intent)
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
    private val notificationHandler = Handler(Looper.getMainLooper())
    private var currentNodeName = "SSRVPN"
    private var connectionStartedAt = 0L
    private var trafficBaselineTx = 0L
    private var trafficBaselineRx = 0L
    private var lastTrafficTx = 0L
    private var lastTrafficRx = 0L
    private var uploadRate = 0L
    private var downloadRate = 0L
    private var notificationConnected = false
    private val notificationUpdater = object : Runnable {
        override fun run() {
            if (!isRunning) return
            updateTrafficStats()
            notifyCurrentState()
            notificationHandler.postDelayed(this, 1000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        // 注册断开广播
        val filter = IntentFilter(ACTION_DISCONNECT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(disconnectReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(disconnectReceiver, filter)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "VPN Service starting...")

        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        currentNodeName = pendingNodeName
            ?: prefs.getString("flutter.selectedNodeName", null)
            ?: "SSRVPN"
        connectionStartedAt = System.currentTimeMillis()
        notificationConnected = false
        resetTrafficStats()

        val notification = buildDynamicNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        isRunning = false

        // 进程被系统杀掉后 START_STICKY 重启时，静态字段已丢失，回退读持久化配置
        val configDir = pendingConfigDir ?: prefs.getString("flutter.configDir", null)
        val configPath = pendingConfigPath ?: prefs.getString("flutter.configPath", null)
        val apiPort = if (pendingConfigDir != null) pendingApiPort
                      else prefs.getLong("flutter.apiPort", 9090L).toInt()
        val apiSecret = if (pendingConfigDir != null) pendingApiSecret ?: ""
                        else prefs.getString("flutter.apiSecret", "") ?: ""
        val selectedNodeName = currentNodeName
        pendingApiSecret = null
        pendingNodeName = null

        if (configDir == null || configPath == null) {
            Log.e(TAG, "Missing parameters!")
            consumeStartResult(false, "Missing parameters")
            stopAll()
            return START_NOT_STICKY
        }

        Thread {
            startCoreWithVpn(configDir, configPath, apiPort, apiSecret, selectedNodeName)
        }.start()

        return START_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "SSRVPN", NotificationManager.IMPORTANCE_LOW).apply {
                description = "VPN 连接状态"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildDynamicNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val openPending = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val disconnectPending = PendingIntent.getBroadcast(
            this,
            1,
            Intent(ACTION_DISCONNECT).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val rateText = if (notificationConnected) {
            "↑ ${formatBytes(uploadRate)}/s  ↓ ${formatBytes(downloadRate)}/s"
        } else {
            "正在连接 VPN..."
        }
        val detailText = if (notificationConnected) {
            "$rateText\n上传 ${formatBytes(sessionUpload())}  下载 ${formatBytes(sessionDownload())}"
        } else {
            rateText
        }
        return builder
            .setContentTitle(currentNodeName)
            .setContentText(rateText)
            .setStyle(Notification.BigTextStyle().bigText(detailText))
            .setSmallIcon(R.drawable.ic_vpn_tile)
            .setContentIntent(openPending)
            .addAction(Notification.Action.Builder(null, "断开", disconnectPending).build())
            .setWhen(connectionStartedAt)
            .setShowWhen(true)
            .setColor(Color.rgb(71, 108, 255))
            .setTicker(if (notificationConnected) "VPN 已连接" else "VPN 正在连接")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
    }

    fun updateNotificationNode(nodeName: String) {
        if (nodeName.isBlank()) return
        currentNodeName = nodeName
        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit()
            .putString("flutter.selectedNodeName", nodeName)
            .apply()
        notifyCurrentState()
    }

    private fun notifyCurrentState() {
        if (!isRunning) return
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildDynamicNotification())
    }

    private fun resetTrafficStats() {
        val tx = TrafficStats.getUidTxBytes(applicationInfo.uid).coerceAtLeast(0L)
        val rx = TrafficStats.getUidRxBytes(applicationInfo.uid).coerceAtLeast(0L)
        trafficBaselineTx = tx
        trafficBaselineRx = rx
        lastTrafficTx = tx
        lastTrafficRx = rx
        uploadRate = 0L
        downloadRate = 0L
    }

    private fun updateTrafficStats() {
        val tx = TrafficStats.getUidTxBytes(applicationInfo.uid).coerceAtLeast(0L)
        val rx = TrafficStats.getUidRxBytes(applicationInfo.uid).coerceAtLeast(0L)
        uploadRate = (tx - lastTrafficTx).coerceAtLeast(0L)
        downloadRate = (rx - lastTrafficRx).coerceAtLeast(0L)
        lastTrafficTx = tx
        lastTrafficRx = rx
    }

    private fun sessionUpload(): Long =
        (lastTrafficTx - trafficBaselineTx).coerceAtLeast(0L)

    private fun sessionDownload(): Long =
        (lastTrafficRx - trafficBaselineRx).coerceAtLeast(0L)

    private fun formatBytes(bytes: Long): String {
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
            String.format(java.util.Locale.US, "%.1f %s", value, units[unitIndex])
        }
    }

    private fun startNotificationUpdates() {
        notificationConnected = true
        notificationHandler.removeCallbacks(notificationUpdater)
        notificationHandler.post(notificationUpdater)
    }

    private fun stopNotificationUpdates() {
        notificationHandler.removeCallbacks(notificationUpdater)
        notificationConnected = false
    }

    /**
     * 添加公网路由，排除局域网网段：
     * 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10
     * 这样局域网流量（adb无线调试、投屏、局域网设备）走WiFi直连
     */
    private fun addPublicRoutes(builder: VpnService.Builder) {
        // 0.0.0.0/1 + 128.0.0.0/1 = 整个 IPv4，然后逐个排除局域网段
        // 由于 Android API 不支持 exclude，我们手动划分公网子网

        // 1.0.0.0/8 ~ 9.255.255.255
        builder.addRoute("1.0.0.0", 8)
        // 11.0.0.0/8 ~ 126.255.255.255 (跳过 10.x.x.x)
        builder.addRoute("11.0.0.0", 8)
        builder.addRoute("12.0.0.0", 6)   // 12-15
        builder.addRoute("16.0.0.0", 4)   // 16-31
        builder.addRoute("32.0.0.0", 3)   // 32-63
        builder.addRoute("64.0.0.0", 3)   // 64-95 (跳过 100.64.0.0/10)
        // 96.0.0.0/6 = 96-99
        builder.addRoute("96.0.0.0", 6)
        // 100.0.0.0/10 = 100.0-100.63 (跳过 100.64.0.0/10)
        builder.addRoute("100.0.0.0", 10)
        // 100.128.0.0/9 = 100.128-100.255
        builder.addRoute("100.128.0.0", 9)
        // 101.0.0.0/8 ~ 171.255.255.255
        builder.addRoute("101.0.0.0", 8)
        builder.addRoute("102.0.0.0", 7)   // 102-103
        builder.addRoute("104.0.0.0", 5)   // 104-111
        builder.addRoute("112.0.0.0", 4)   // 112-127
        builder.addRoute("128.0.0.0", 3)   // 128-159
        builder.addRoute("160.0.0.0", 5)   // 160-167
        builder.addRoute("168.0.0.0", 7)   // 168-169 (跳过 172.16.0.0/12)
        // 172.0.0.0/12 = 172.0-172.15
        builder.addRoute("172.0.0.0", 12)
        // 172.32.0.0/11 = 172.32-172.63
        builder.addRoute("172.32.0.0", 11)
        // 172.64.0.0/10 = 172.64-172.127
        builder.addRoute("172.64.0.0", 10)
        // 172.128.0.0/9 = 172.128-172.255
        builder.addRoute("172.128.0.0", 9)
        // 173.0.0.0/8 ~ 191.255.255.255
        builder.addRoute("173.0.0.0", 8)
        builder.addRoute("174.0.0.0", 7)   // 174-175
        builder.addRoute("176.0.0.0", 4)   // 176-191
        // 192.0.0.0/16 = 192.0.0.0 ~ 192.0.255.255 (跳过 192.168.x.x)
        builder.addRoute("192.0.0.0", 16)
        // 192.1.0.0/16 ~ 192.167.255.255
        builder.addRoute("192.1.0.0", 16)
        builder.addRoute("192.2.0.0", 15)   // 192.2-192.3
        builder.addRoute("192.4.0.0", 14)   // 192.4-192.7
        builder.addRoute("192.8.0.0", 13)   // 192.8-192.15
        builder.addRoute("192.16.0.0", 12)  // 192.16-192.31
        builder.addRoute("192.32.0.0", 11)  // 192.32-192.63
        builder.addRoute("192.64.0.0", 10)  // 192.64-192.127
        builder.addRoute("192.128.0.0", 11) // 192.128-192.159
        builder.addRoute("192.160.0.0", 13) // 192.160-192.167 (跳过 192.168.x.x)
        builder.addRoute("192.169.0.0", 16)
        builder.addRoute("192.170.0.0", 15) // 192.170-192.171
        builder.addRoute("192.172.0.0", 14) // 192.172-192.175
        builder.addRoute("192.176.0.0", 12) // 192.176-192.191
        builder.addRoute("192.192.0.0", 10) // 192.192-192.255
        // 193.0.0.0/8 ~ 223.255.255.255
        builder.addRoute("193.0.0.0", 8)
        builder.addRoute("194.0.0.0", 7)   // 194-195
        builder.addRoute("196.0.0.0", 6)   // 196-199
        builder.addRoute("200.0.0.0", 5)   // 200-207
        builder.addRoute("208.0.0.0", 4)   // 208-223
        // 224.0.0.0/4 = 组播，通常不需要
        // 忽略
    }

    private fun startCoreWithVpn(
        configDir: String,
        configPath: String,
        apiPort: Int,
        apiSecret: String,
        selectedNodeName: String?
    ) {
        val packageName = packageName
        try {
            // Step 1: Initialize protect pipe
            Log.d(TAG, "Initializing protect pipe...")
            val protectReadFd = bridge.Bridge.initProtect()
            Log.d(TAG, "Protect pipe fd=$protectReadFd")

            // Step 2: Start protect monitor thread (reads fd, calls protect, sends result)
            if (protectReadFd > 0) {
                protectThread = Thread {
                    try {
                        val pfd = ParcelFileDescriptor.fromFd(protectReadFd.toInt())
                        val fis = FileInputStream(pfd.fileDescriptor)
                        val buf = ByteArray(4)
                        while (!Thread.currentThread().isInterrupted) {
                            val n = fis.read(buf)
                            if (n == 4) {
                                val socketFd = (buf[0].toInt() and 0xFF) or
                                    ((buf[1].toInt() and 0xFF) shl 8) or
                                    ((buf[2].toInt() and 0xFF) shl 16) or
                                    ((buf[3].toInt() and 0xFF) shl 24)
                                val ok = protect(socketFd)
                                Log.d(TAG, "protect($socketFd) = $ok")
                                bridge.Bridge.setProtectResult(ok)
                            } else if (n == -1) {
                                Log.d(TAG, "Protect pipe closed")
                                break
                            }
                        }
                        fis.close()
                        pfd.close()
                    } catch (e: Exception) {
                        Log.e(TAG, "Protect thread error: ${e.message}", e)
                    }
                }
                protectThread?.isDaemon = true
                protectThread?.start()
                Log.d(TAG, "Protect monitor started")
            }

            // Step 3: Establish VPN
            Log.d(TAG, "Establishing VPN...")
            val builder = Builder()
            builder.setSession("SSRVPN")
            builder.addAddress("198.18.0.1", 32)
            // 分段添加路由，排除局域网网段保持 adb 无线调试可达
            // 公网 IPv4: 排除 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10
            addPublicRoutes(builder)
            // 节点与核心配置明确为 IPv4-only。不要添加 IPv6 默认路由，
            // 否则 IPv6 流量会进入未处理的 TUN，表现为已连接但部分应用断网。
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
                consumeStartResult(false, "VPN establish failed")
                stopAll()
                return
            }

            val tunFd = vpnFd!!.detachFd().toLong()
            Log.d(TAG, "VPN established! fd=$tunFd")

            if (tunFd <= 0) {
                Log.e(TAG, "Invalid VPN fd")
                consumeStartResult(false, "Invalid VPN fd")
                stopAll()
                return
            }

            // Step 4: Initialize and start Mihomo
            Log.d(TAG, "Initializing Mihomo...")
            bridge.Bridge.init(configDir, "config.yaml")
            val startErr = bridge.Bridge.start(configPath, tunFd)
            if (startErr.isNotEmpty()) {
                Log.e(TAG, "Mihomo start failed: $startErr")
                consumeStartResult(false, "Mihomo: $startErr")
                stopAll()
                return
            }
            Log.d(TAG, "Mihomo started with TUN fd=$tunFd")

            // Step 5: Wait for API health (use dynamic port)
            Log.d(TAG, "Waiting for API on port $apiPort...")
            var healthy = false
            for (i in 0 until 80) {
                Thread.sleep(250)
                try {
                    val socket = java.net.Socket()
                    socket.connect(java.net.InetSocketAddress("127.0.0.1", apiPort), 250)
                    socket.close()
                    healthy = true
                    Log.d(TAG, "API healthy after ${(i + 1) * 250}ms")
                    break
                } catch (_: Exception) {}
            }

            if (healthy) {
                Log.d(TAG, "Core started!")
                applyProxySelection(apiPort, apiSecret, selectedNodeName)
                isRunning = true
                broadcastState(this)
                startNotificationUpdates()
                consumeStartResult(true, "OK")

                Thread {
                    try {
                        while (bridge.Bridge.isRunning()) {
                            Thread.sleep(3000)
                        }
                        // 核心意外退出：必须关闭 VPN 接口并停止前台服务，
                        // 否则全局流量仍被路由进无人读取的 TUN，导致整机断网
                        if (isRunning) {
                            Log.e(TAG, "Mihomo stopped unexpectedly, tearing down VPN")
                            stopAll()
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Monitor error", e)
                    }
                }.start()
            } else {
                Log.e(TAG, "Health check timeout")
                consumeStartResult(false, "设备性能不足，请重新连接")
                stopAll()
            }
        } catch (e: Exception) {
            Log.e(TAG, "startCoreWithVpn error", e)
            consumeStartResult(false, "Error: ${e.message}")
            stopAll()
        }
    }

    private fun applyProxySelection(apiPort: Int, apiSecret: String, nodeName: String?) {
        val selectedNode = nodeName?.takeIf { it.isNotBlank() && it != "SSRVPN" } ?: return
        if (apiSecret.isBlank()) {
            Log.d(TAG, "Skip proxy selection: API secret is only available from Flutter startup")
            return
        }
        val proxyOk = setProxyGroup(apiPort, apiSecret, "PROXY", selectedNode)
        val globalOk = setProxyGroup(apiPort, apiSecret, "GLOBAL", "PROXY") ||
            setProxyGroup(apiPort, apiSecret, "GLOBAL", selectedNode)
        if (proxyOk || globalOk) {
            closeConnections(apiPort, apiSecret)
        }
        Log.d(TAG, "Applied proxy selection: PROXY=$proxyOk GLOBAL=$globalOk node=$selectedNode")
    }

    private fun setProxyGroup(
        apiPort: Int,
        apiSecret: String,
        groupName: String,
        targetName: String
    ): Boolean {
        val encodedGroup = URLEncoder.encode(groupName, "UTF-8").replace("+", "%20")
        val body = JSONObject().put("name", targetName).toString()
        val code = apiRequest(apiPort, apiSecret, "PUT", "/proxies/$encodedGroup", body)
        return code == 200 || code == 204
    }

    private fun closeConnections(apiPort: Int, apiSecret: String) {
        apiRequest(apiPort, apiSecret, "DELETE", "/connections", null)
    }

    private fun apiRequest(
        apiPort: Int,
        apiSecret: String,
        method: String,
        path: String,
        body: String?
    ): Int {
        var connection: HttpURLConnection? = null
        return try {
            val url = URL("http://127.0.0.1:$apiPort$path")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = 1500
                readTimeout = 1500
                if (apiSecret.isNotBlank()) {
                    setRequestProperty("Authorization", "Bearer $apiSecret")
                }
                if (body != null) {
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                }
            }
            connection = conn
            if (body != null) {
                conn.outputStream.use { stream ->
                    stream.write(body.toByteArray(Charsets.UTF_8))
                }
            }
            val code = conn.responseCode
            try {
                val stream = if (code >= 400) conn.errorStream else conn.inputStream
                stream?.close()
            } catch (_: Exception) {}
            code
        } catch (e: Exception) {
            Log.d(TAG, "API $method $path failed: ${e.message}")
            -1
        } finally {
            connection?.disconnect()
        }
    }

    @Synchronized
    fun stopAll() {
        Log.d(TAG, "Stopping...")
        stopNotificationUpdates()
        protectThread?.interrupt()
        protectThread = null
        try {
            bridge.Bridge.stop()
        } catch (e: Exception) {
            Log.e(TAG, "Bridge stop error", e)
        }
        try { vpnFd?.close() } catch (_: Exception) {}
        vpnFd = null
        isRunning = false
        broadcastState(this)
        // 修复: 使用兼容 Android 13+ 的方式停止前台服务
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
        Log.d(TAG, "Stopped")
    }

    override fun onDestroy() {
        super.onDestroy()
        try { unregisterReceiver(disconnectReceiver) } catch (_: Exception) {}
        stopAll()
        instance = null
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
