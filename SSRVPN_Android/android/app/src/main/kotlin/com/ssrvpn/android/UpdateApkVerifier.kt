package com.ssrvpn.android

import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import java.io.File

internal data class UpdateApkIdentity(
    val packageName: String,
    val versionCode: Long,
    val currentSigners: Set<List<Byte>>,
    val signingHistory: Set<List<Byte>>,
    val hasMultipleSigners: Boolean,
)

internal object UpdateApkVerifier {
    fun verify(packageManager: PackageManager, installedPackageName: String, apkFile: File) {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val installed = packageManager.installedPackageInfo(installedPackageName, flags)
        val candidate = packageManager.archivePackageInfo(apkFile.absolutePath, flags)
            ?: throw SecurityException("无法读取 APK 包信息，已取消安装")
        val installedIdentity = installed.toIdentity()
        val candidateIdentity = candidate.toIdentity()

        if (candidateIdentity.packageName != installedIdentity.packageName) {
            throw SecurityException("APK 包名与当前应用不匹配，已取消安装")
        }
        if (candidateIdentity.versionCode < installedIdentity.versionCode) {
            throw SecurityException("APK 版本低于当前应用，已取消安装")
        }
        if (!isTrustedUpdate(installedIdentity, candidateIdentity)) {
            throw SecurityException("APK 签名证书与当前应用不匹配，已取消安装")
        }
    }

    internal fun isTrustedUpdate(
        installed: UpdateApkIdentity,
        candidate: UpdateApkIdentity,
    ): Boolean {
        if (candidate.packageName != installed.packageName ||
            candidate.versionCode < installed.versionCode ||
            installed.currentSigners.isEmpty() || candidate.currentSigners.isEmpty() ||
            !installed.signingHistory.containsAll(installed.currentSigners) ||
            !candidate.signingHistory.containsAll(candidate.currentSigners)
        ) {
            return false
        }

        if (installed.hasMultipleSigners || candidate.hasMultipleSigners) {
            return installed.hasMultipleSigners &&
                candidate.hasMultipleSigners &&
                installed.currentSigners == candidate.currentSigners
        }

        return candidate.signingHistory.containsAll(installed.currentSigners)
    }

    @Suppress("DEPRECATION")
    private fun PackageManager.installedPackageInfo(packageName: String, flags: Int): PackageInfo {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            getPackageInfo(packageName, flags)
        }
    }

    @Suppress("DEPRECATION")
    private fun PackageManager.archivePackageInfo(path: String, flags: Int): PackageInfo? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            getPackageArchiveInfo(path, flags)
        }
    }

    @Suppress("DEPRECATION")
    private fun PackageInfo.toIdentity(): UpdateApkIdentity {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            val current = signatures.toCertificateSet()
            return UpdateApkIdentity(
                packageName,
                normalizedVersionCode(),
                current,
                current,
                current.size > 1,
            )
        }

        val info = signingInfo
            ?: return UpdateApkIdentity(
                packageName,
                normalizedVersionCode(),
                emptySet(),
                emptySet(),
                false,
            )
        val multipleSigners = info.hasMultipleSigners()
        val signerHistory = if (multipleSigners) {
            info.apkContentsSigners.orEmpty()
        } else {
            info.signingCertificateHistory.orEmpty()
        }
        val history = signerHistory.toCertificateSet()
        val current = if (multipleSigners) {
            history
        } else {
            signerHistory.lastOrNull()?.toCertificate()?.let(::setOf).orEmpty()
        }
        return UpdateApkIdentity(
            packageName,
            normalizedVersionCode(),
            current,
            history,
            multipleSigners,
        )
    }

    @Suppress("DEPRECATION")
    private fun PackageInfo.normalizedVersionCode(): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) longVersionCode else versionCode.toLong()

    private fun Array<out Signature>?.toCertificateSet(): Set<List<Byte>> =
        orEmpty().mapTo(linkedSetOf()) { it.toCertificate() }

    private fun Signature.toCertificate(): List<Byte> = toByteArray().toList()
}
