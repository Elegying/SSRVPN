package com.ssrvpn.android

import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class AndroidRecentTasksVisibility(private val activity: Activity) {
    private val preferences by lazy {
        activity.getSharedPreferences("ssrvpn_task_visibility", Context.MODE_PRIVATE)
    }
    private var channel: MethodChannel? = null
    private val controller = RecentTasksVisibilityController(
        readPreference = { preferences.getBoolean("hide_from_recents", false) },
        writePreference = { enabled ->
            check(preferences.edit().putBoolean("hide_from_recents", enabled).commit()) {
                "RECENTS_PREFERENCE_WRITE_FAILED"
            }
        },
        tasks = ::mainTasks
    )

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "com.ssrvpn/recent_tasks").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "getEnabled" && call.method != "setEnabled") {
                    result.notImplemented()
                } else if (call.method == "setEnabled" && call.arguments !is Boolean) {
                    result.error("INVALID_ARGUMENT", "Expected a boolean", null)
                } else {
                    try {
                        check(!activity.isFinishing && !activity.isDestroyed)
                        result.success(if (call.method == "getEnabled") controller.restore()
                            else controller.setEnabled(call.arguments as Boolean))
                    } catch (_: Exception) {
                        result.error("RECENTS_VISIBILITY_FAILED", "Unable to update task visibility", null)
                    }
                }
            }
        }
        restore()
    }

    fun restore() {
        AndroidRuntimeGuard.run("TaskVisibility", "Unable to restore task visibility") {
            controller.restore()
        }
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    @Suppress("DEPRECATION") // RecentTaskInfo.taskId requires API 29; id supports our older devices.
    private fun mainTasks(): List<RecentTasksVisibilityController.Task> {
        val manager = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val component = ComponentName(activity, MainActivity::class.java)
        val tasks = manager.appTasks.filter { it.taskInfo.baseIntent.component == component }
        check(tasks.any { it.taskInfo.id == activity.taskId }) { "RECENTS_TASK_UNAVAILABLE" }
        // The separate disconnect-recovery task must always remain excluded.
        return tasks.map { task ->
            object : RecentTasksVisibilityController.Task {
                override val excluded: Boolean
                    get() = task.taskInfo.baseIntent.flags and Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS != 0

                override fun setExcluded(value: Boolean) {
                    task.setExcludeFromRecents(value)
                    check(excluded == value) { "RECENTS_VISIBILITY_NOT_APPLIED" }
                }
            }
        }
    }
}
