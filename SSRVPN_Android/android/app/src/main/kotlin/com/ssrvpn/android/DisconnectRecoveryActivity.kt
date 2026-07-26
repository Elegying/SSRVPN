package com.ssrvpn.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log

class DisconnectRecoveryActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private val relaunch = Runnable {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_NO_ANIMATION
        )
        startActivity(launchIntent)
        finishAndRemoveTask()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handler.postDelayed(relaunch, RELAUNCH_DELAY_MS)
    }

    override fun onDestroy() {
        handler.removeCallbacks(relaunch)
        super.onDestroy()
    }

    companion object {
        private const val TAG = "DisconnectRecovery"
        private const val RELAUNCH_DELAY_MS = 1_500L

        fun handoff(context: Context) {
            try {
                context.startActivity(
                    Intent(context, DisconnectRecoveryActivity::class.java).addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or
                            Intent.FLAG_ACTIVITY_NO_ANIMATION
                    )
                )
            } catch (error: Exception) {
                Log.e(TAG, "Unable to preserve foreground UI during core reset", error)
            }
        }
    }
}
