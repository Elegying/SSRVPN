package com.ssrvpn.android

import android.content.Context
import android.util.Log

/** Serializes user-visible snapshot commits with native start/stop epochs. */
internal class NativeSessionCommitter(
    private val context: Context,
    private val gate: StartGenerationGate,
    private val running: () -> Boolean,
    private val onNodeCommitted: (String) -> Unit
) {
    fun updateNode(nodeName: String, expectedSessionGeneration: Long): Boolean {
        if (nodeName.isBlank()) return false
        var updated = false
        val accepted = gate.runIfCurrent(expectedSessionGeneration) {
            if (!running()) return@runIfCurrent
            try {
                NativeConnectionSnapshotStore.updateSelectedNode(context, nodeName)
                onNodeCommitted(nodeName)
                updated = true
            } catch (error: Exception) {
                Log.e("NativeSessionCommitter", "Unable to update node snapshot", error)
            }
        }
        return accepted && updated
    }

    fun commitSnapshot(
        expectedSessionGeneration: Long,
        snapshot: NativeConnectionSnapshot
    ): String? {
        var generation: String? = null
        gate.runIfCurrent(expectedSessionGeneration) {
            if (running()) {
                generation = NativeConnectionSnapshotStore.write(context, snapshot)
                snapshot.selectedNodeName?.let(onNodeCommitted)
            }
        }
        return generation
    }
}
