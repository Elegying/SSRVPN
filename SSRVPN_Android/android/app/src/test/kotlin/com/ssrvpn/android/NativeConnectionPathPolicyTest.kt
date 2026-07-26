package com.ssrvpn.android

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class NativeConnectionPathPolicyTest {
    @Test
    fun `snapshot paths must resolve inside the private app directory`() {
        val root = Files.createTempDirectory("ssrvpn-private-root").toFile()
        try {
            val configDir = File(root, "app_flutter/runtime").apply { mkdirs() }
            val config = File(configDir, "config.yaml").apply {
                writeText("mixed-port: 7890")
            }
            val trusted = NativeConnectionPathPolicy.requireTrusted(
                root.path,
                snapshot(configDir, config)
            )

            assertEquals(configDir.canonicalPath, trusted.configDir)
            assertEquals(config.canonicalPath, trusted.configPath)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `sibling prefix traversal and symlink escapes are rejected`() {
        val parent = Files.createTempDirectory("ssrvpn-path-policy").toFile()
        try {
            val root = File(parent, "app-data").apply { mkdirs() }
            val sibling = File(parent, "app-data-evil").apply { mkdirs() }
            val siblingConfig = File(sibling, "config.yaml").apply {
                writeText("mixed-port: 7890")
            }
            assertThrows(IllegalArgumentException::class.java) {
                NativeConnectionPathPolicy.requireTrusted(
                    root.path,
                    snapshot(sibling, siblingConfig)
                )
            }

            val link = File(root, "escaped")
            Files.createSymbolicLink(link.toPath(), sibling.toPath())
            assertThrows(IllegalArgumentException::class.java) {
                NativeConnectionPathPolicy.requireTrusted(
                    root.path,
                    snapshot(link, File(link, "config.yaml"))
                )
            }
        } finally {
            parent.deleteRecursively()
        }
    }

    @Test
    fun `config must be a regular file inside the declared config directory`() {
        val root = Files.createTempDirectory("ssrvpn-config-policy").toFile()
        try {
            val firstDir = File(root, "first").apply { mkdirs() }
            val secondDir = File(root, "second").apply { mkdirs() }
            val outsideDeclaredDir = File(secondDir, "config.yaml").apply {
                writeText("mixed-port: 7890")
            }
            assertThrows(IllegalArgumentException::class.java) {
                NativeConnectionPathPolicy.requireTrusted(
                    root.path,
                    snapshot(firstDir, outsideDeclaredDir)
                )
            }
            assertThrows(IllegalArgumentException::class.java) {
                NativeConnectionPathPolicy.requireTrusted(
                    root.path,
                    snapshot(firstDir, File(firstDir, "missing.yaml"))
                )
            }
        } finally {
            root.deleteRecursively()
        }
    }

    private fun snapshot(
        configDir: File,
        configPath: File
    ) = NativeConnectionSnapshot(
        configDir = configDir.path,
        configPath = configPath.path,
        apiPort = 9090,
        apiSecret = "test-secret",
        selectedNodeName = "Node A"
    )
}
