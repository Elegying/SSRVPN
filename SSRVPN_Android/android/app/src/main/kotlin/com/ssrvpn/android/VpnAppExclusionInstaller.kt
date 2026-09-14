package com.ssrvpn.android

import android.content.pm.PackageManager
import android.net.VpnService
import java.io.File

internal object VpnAppExclusionInstaller {
    private const val HEADER = "# ssrvpn-direct-apps: "
    private val packagePattern = Regex("[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z][A-Za-z0-9_]*)+")

    // Metadata lives in the same protected config as proxy rules, so tile and
    // process-recovery starts cannot mix application-list versions.
    internal fun packagesFromConfig(file: File): List<String> =
        file.bufferedReader().use { reader ->
            packagesFromHeader(reader.lineSequence().take(4).toList())
        }

    internal fun packagesFromHeader(lines: List<String>): List<String> {
        val headers = lines.filter { it.startsWith(HEADER) }
        require(headers.size <= 1) { "Duplicate application-list metadata" }
        if (headers.isEmpty()) return DomesticAppBypassPolicy.packageNames
        val content = headers.single().removePrefix(HEADER)
        require(content.length <= 4 * 1024 * 1024)
        if (content.isEmpty()) return emptyList()
        val packages = content.split(',')
        require(packages.size <= 200000 && packages.size == packages.toSet().size)
        require(packages.all { it.length <= 255 && packagePattern.matches(it) && it != "com.ssrvpn.android" })
        return packages
    }
    private val adbPackages = listOf(
        "com.android.adb",
        "com.google.android.adb"
    )

    fun install(
        builder: VpnService.Builder,
        bypassDomesticApps: Boolean,
        domesticPackages: List<String>,
        browserPackages: Set<String>
    ): List<String> = install(bypassDomesticApps, domesticPackages, browserPackages) { packageName ->
        addIfInstalled(builder, packageName)
    }

    internal fun install(
        bypassDomesticApps: Boolean,
        domesticPackages: List<String> = DomesticAppBypassPolicy.packageNames,
        browserPackages: Set<String> = emptySet(),
        addDisallowedApplication: (String) -> Boolean
    ): List<String> {
        val bypassedDomesticApps = if (bypassDomesticApps) {
            domesticPackages.filter { it != "com.ssrvpn.android" && it !in browserPackages }
                .filter(addDisallowedApplication)
        } else emptyList()
        adbPackages.forEach { packageName ->
            addDisallowedApplication(packageName)
        }
        return bypassedDomesticApps
    }

    private fun addIfInstalled(
        builder: VpnService.Builder,
        packageName: String
    ): Boolean = try {
        builder.addDisallowedApplication(packageName)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }
}
