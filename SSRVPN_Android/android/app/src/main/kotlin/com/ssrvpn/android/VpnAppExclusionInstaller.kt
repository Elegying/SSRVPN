package com.ssrvpn.android

import android.content.pm.PackageManager
import android.net.VpnService

internal object VpnAppExclusionInstaller {
    private val adbPackages = listOf(
        "com.android.adb",
        "com.google.android.adb"
    )

    fun install(builder: VpnService.Builder): List<String> =
        install { packageName -> addIfInstalled(builder, packageName) }

    internal fun install(addDisallowedApplication: (String) -> Boolean): List<String> {
        val bypassedDomesticApps = DomesticAppBypassPolicy.applyInstalled { packageName ->
            addDisallowedApplication(packageName)
        }
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
