package com.ssrvpn.android

/** Owns preference/task rollback without changing the VPN or Activity lifetime. */
internal class RecentTasksVisibilityController(
    private val readPreference: () -> Boolean,
    private val writePreference: (Boolean) -> Unit,
    private val tasks: () -> List<Task>
) {
    interface Task {
        val excluded: Boolean
        fun setExcluded(value: Boolean)
    }

    fun restore(): Boolean = apply(readPreference(), persist = false)

    fun setEnabled(enabled: Boolean): Boolean = apply(enabled, persist = true)

    private fun apply(enabled: Boolean, persist: Boolean): Boolean {
        val previous = readPreference()
        val snapshots = tasks().map { it to it.excluded }
        check(snapshots.isNotEmpty()) { "RECENTS_TASK_UNAVAILABLE" }
        val attempted = mutableListOf<Pair<Task, Boolean>>()
        var writeAttempted = false
        try {
            for ((task, before) in snapshots) {
                if (before == enabled) continue
                attempted += task to before
                task.setExcluded(enabled)
            }
            if (persist && enabled != previous) {
                writeAttempted = true
                writePreference(enabled)
            }
            return enabled
        } catch (failure: Exception) {
            // Include the failing task: a platform call can mutate before failing.
            for ((task, before) in attempted.asReversed()) {
                try {
                    task.setExcluded(before)
                } catch (rollback: Exception) {
                    failure.addSuppressed(rollback)
                }
            }
            if (writeAttempted) {
                try {
                    writePreference(previous)
                } catch (rollback: Exception) {
                    failure.addSuppressed(rollback)
                }
            }
            throw failure
        }
    }
}
