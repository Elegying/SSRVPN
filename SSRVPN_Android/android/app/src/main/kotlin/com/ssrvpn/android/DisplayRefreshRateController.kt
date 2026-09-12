package com.ssrvpn.android

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings

/** Window-local preference. The system retains control over power/thermal/OEM limits. */
internal class DisplayRefreshRateController(private val activity: Activity) {
    private val handler = Handler(Looper.getMainLooper())
    private val displays = activity.getSystemService(DisplayManager::class.java)
    private var active = false
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
        activity.contentResolver.registerContentObserver(
            Settings.System.getUriFor("peak_refresh_rate"), false, settingsObserver)
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
        val configuredPeak = Settings.System.getFloat(activity.contentResolver, "peak_refresh_rate", 120f)
        val cap = if (powerSaving) 60f else if (configuredPeak.isFinite() && configuredPeak > 0f) {
            configuredPeak.coerceAtMost(120f)
        } else 120f
        val preferred = display.supportedModes.asSequence()
            .filter { it.physicalWidth == mode.physicalWidth && it.physicalHeight == mode.physicalHeight }
            .map { it.refreshRate }
            .filter { it <= cap + 0.1f }
            .maxOrNull() ?: 0f
        val attributes = activity.window.attributes
        if (kotlin.math.abs(attributes.preferredRefreshRate - preferred) > 0.1f) {
            attributes.preferredRefreshRate = preferred
            activity.window.attributes = attributes
        }
    }

    fun stop() {
        if (!active) return
        active = false
        activity.contentResolver.unregisterContentObserver(settingsObserver)
        displays.unregisterDisplayListener(displayListener)
        activity.unregisterReceiver(powerReceiver)
        val attributes = activity.window.attributes
        attributes.preferredRefreshRate = 0f
        activity.window.attributes = attributes
    }
}
