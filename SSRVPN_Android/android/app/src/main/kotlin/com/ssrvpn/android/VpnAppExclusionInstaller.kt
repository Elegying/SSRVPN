package com.ssrvpn.android

import android.content.pm.PackageManager
import android.net.VpnService

internal object VpnAppExclusionInstaller {
    private val adbPackages = listOf(
        "com.android.adb",
        "com.google.android.adb"
    )

    fun install(
        builder: VpnService.Builder,
        vpnPackageName: String
    ): List<String> {
        builder.addDisallowedApplication(vpnPackageName)
        val bypassedDomesticApps = DomesticAppBypassPolicy.applyInstalled { packageName ->
            addIfInstalled(builder, packageName)
        }
        adbPackages.forEach { addIfInstalled(builder, it) }
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
