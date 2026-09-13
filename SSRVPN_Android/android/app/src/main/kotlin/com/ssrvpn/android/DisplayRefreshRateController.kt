package com.ssrvpn.android

import android.app.Activity
import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import java.io.File
import android.view.Surface
import android.view.SurfaceHolder
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterSurfaceView

/** Window-local preference. The system retains control over power/thermal/OEM limits. */
internal class DisplayRefreshRateController(private val activity: Activity) {
    private val handler = Handler(Looper.getMainLooper())
    private val displays = activity.getSystemService(DisplayManager::class.java)
    private var active = false
    private var surfaceHolder: SurfaceHolder? = null
    private var requestedSurfaceRate = Float.NaN
    private val surfaceCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) { requestedSurfaceRate = Float.NaN; update() }
        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            requestedSurfaceRate = Float.NaN
            update()
        }
        override fun surfaceDestroyed(holder: SurfaceHolder) { requestedSurfaceRate = Float.NaN }
    }
    private val layoutListener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> update() }

    private fun findFlutterSurface(view: View): FlutterSurfaceView? {
        if (view is FlutterSurfaceView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findFlutterSurface(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    private fun requestSurfaceRate(rate: Float) {
        if (Build.VERSION.SDK_INT < 30) return
        val holder = findFlutterSurface(activity.window.decorView)?.holder ?: return
        if (surfaceHolder !== holder) {
            surfaceHolder?.removeCallback(surfaceCallback)
            surfaceHolder = holder
            holder.addCallback(surfaceCallback)
            requestedSurfaceRate = Float.NaN
        }
        if (holder.surface.isValid && requestedSurfaceRate != rate) {
            // A window mode preference alone does not set the app's render-rate
            // vote on adaptive-refresh displays. Vote on Flutter's actual surface.
            runCatching { holder.surface.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT) }
                .onSuccess { requestedSurfaceRate = rate }
        }
    }
    val lowPerformance: Boolean by lazy {
        val manager = activity.getSystemService(ActivityManager::class.java)
        val memory = ActivityManager.MemoryInfo().also(manager::getMemoryInfo)
        val maxCpuKhz = runCatching {
            File("/sys/devices/system/cpu/cpufreq").listFiles()
                ?.filter { it.name.startsWith("policy") }
                ?.mapNotNull { runCatching {
                    File(it, "cpuinfo_max_freq").readText().trim().toLongOrNull()
                }.getOrNull() }
                ?.maxOrNull()
        }.getOrNull()
        // Small-heap, older CPU devices can have 6 GB RAM and still be slow
        // at high-DPR glass. Missing sysfs access must not prevent startup.
        manager.isLowRamDevice || memory.totalMem <= 3L * 1024 * 1024 * 1024 ||
            (manager.memoryClass <= 128 && (maxCpuKhz == null || maxCpuKhz <= 2_100_000))
    }
    private val settingNames = listOf(
        "peak_refresh_rate", "min_refresh_rate", "is_smart_fps",
        "user_refresh_rate", "miui_refresh_rate")
    private val settingsObserver = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) = update()
    }
    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = update()
    }
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = update()
        override fun onDisplayRemoved(displayId: Int) = update()
        override fun onDisplayChanged(displayId: Int) = update()
    }

    fun start() {
        if (active) return
        active = true
        activity.window.decorView.addOnLayoutChangeListener(layoutListener)
        for (name in settingNames) {
            activity.contentResolver.registerContentObserver(
                Settings.System.getUriFor(name), false, settingsObserver)
            activity.contentResolver.registerContentObserver(
                Settings.Secure.getUriFor(name), false, settingsObserver)
        }
        displays.registerDisplayListener(displayListener, handler)
        activity.registerReceiver(powerReceiver, IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED))
        update()
    }

    @Suppress("DEPRECATION")
    private fun update() {
        if (!active) return
        val display = activity.window.decorView.display ?: return
        val mode = display.mode
        val powerSaving = activity.getSystemService(PowerManager::class.java).isPowerSaveMode
        fun setting(name: String): Float? {
            val resolver = activity.contentResolver
            return (Settings.System.getString(resolver, name)
                ?: Settings.Secure.getString(resolver, name))?.toFloatOrNull()
        }
        val automatic = setting("is_smart_fps") == 1f
        val configuredPeak = if (automatic) null else
            setting("user_refresh_rate")?.takeIf { it > 0f }
                ?: setting("peak_refresh_rate")?.takeIf { it > 0f }
        val modes = display.supportedModes.filter {
            it.physicalWidth == mode.physicalWidth && it.physicalHeight == mode.physicalHeight
        }
        val preferred = preferredDisplayRefreshRate(
            modes.map { it.refreshRate }, configuredPeak, lowPerformance || powerSaving)
        requestSurfaceRate(preferred)
        val attributes = activity.window.attributes
        val preferredMode = modes.firstOrNull {
            kotlin.math.abs(it.refreshRate - preferred) < 0.1f
        }?.modeId ?: 0
        if (kotlin.math.abs(attributes.preferredRefreshRate - preferred) > 0.1f ||
            attributes.preferredDisplayModeId != preferredMode) {
            attributes.preferredRefreshRate = preferred
            attributes.preferredDisplayModeId = preferredMode
            activity.window.attributes = attributes
        }
    }

    fun stop() {
        if (!active) return
        active = false
        activity.window.decorView.removeOnLayoutChangeListener(layoutListener)
        if (Build.VERSION.SDK_INT >= 30) {
            surfaceHolder?.surface?.takeIf { it.isValid }?.let {
                runCatching { it.setFrameRate(0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT) }
            }
        }
        surfaceHolder?.removeCallback(surfaceCallback)
        surfaceHolder = null
        requestedSurfaceRate = Float.NaN
        activity.contentResolver.unregisterContentObserver(settingsObserver)
        displays.unregisterDisplayListener(displayListener)
        activity.unregisterReceiver(powerReceiver)
        val attributes = activity.window.attributes
        attributes.preferredRefreshRate = 0f
        attributes.preferredDisplayModeId = 0
        activity.window.attributes = attributes
    }
}

/** Null/invalid system preference means automatic, with no arbitrary 120 Hz ceiling. */
internal fun preferredDisplayRefreshRate(
    supported: List<Float>, configured: Float?, limited: Boolean
): Float {
    val rates = supported.filter { it.isFinite() && it > 0f }
    val cap = if (limited) 60f else configured?.takeIf { it.isFinite() && it > 0f }
    return rates.filter { cap == null || it <= cap + 0.1f }.maxOrNull()
        ?: rates.minOrNull() ?: 0f
}
