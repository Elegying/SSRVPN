package com.ssrvpn.android

import java.io.File

/** Confines native runtime snapshots to regular files in app-private storage. */
internal object NativeConnectionPathPolicy {
    fun requireTrusted(
        appDataDir: String,
        snapshot: NativeConnectionSnapshot
    ): NativeConnectionSnapshot {
        val privateRoot = File(appDataDir).canonicalFile
        require(privateRoot.isDirectory) { "Private app directory is unavailable" }

        val configDir = File(snapshot.configDir).canonicalFile
        val configPath = File(snapshot.configPath).canonicalFile
        require(configDir.isDirectory && isWithin(privateRoot, configDir)) {
            "Config directory is outside private app storage"
        }
        require(configPath.isFile && isWithin(configDir, configPath)) {
            "Config path is not a regular file inside the config directory"
        }
        return snapshot.copy(
            configDir = configDir.path,
            configPath = configPath.path
        )
    }

    private fun isWithin(parent: File, child: File): Boolean {
        val parentPath = parent.path
        val childPath = child.path
        return childPath == parentPath ||
            childPath.startsWith(parentPath + File.separator)
    }
}
