package com.ssrvpn.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.OsConstants
import org.json.JSONArray
import java.net.InetAddress
import java.net.InetSocketAddress

/** Local-only flow ownership lookup. Never uploads installed application data. */
internal object VpnPackageLookup {
    fun start(context: Context): Thread? {
        if (Build.VERSION.SDK_INT < 29) return null
        val browsers = browserPackages(context) ?: return null
        return startLookup(context, browsers)
    }

    internal fun browserPackages(context: Context): Set<String>? {
        val browserIntent = Intent(Intent.ACTION_VIEW, Uri.parse("https://ssrvpn-browser-check.invalid/"))
            .addCategory(Intent.CATEGORY_BROWSABLE)
        return try {
            context.packageManager.queryIntentActivities(browserIntent, PackageManager.MATCH_DEFAULT_ONLY)
                .map { it.activityInfo.packageName }.toSet()
        } catch (_: Exception) { null }
    }

    private fun startLookup(context: Context, browsers: Set<String>): Thread? {
        val fd = bridge.Bridge.initPackageLookup()
        if (fd < 0) return null
        val input = ParcelFileDescriptor.AutoCloseInputStream(ParcelFileDescriptor.adoptFd(fd.toInt()))
        return Thread({
            input.bufferedReader().use { reader ->
                try {
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.length > 512) break
                        val request = JSONArray(line)
                        val id = request.getLong(0)
                        val name = try {
                            val protocol = when (request.getString(1)) {
                                "tcp" -> OsConstants.IPPROTO_TCP
                                "udp" -> OsConstants.IPPROTO_UDP
                                else -> throw IllegalArgumentException("Unsupported protocol")
                            }
                            val source = InetSocketAddress(InetAddress.getByName(request.getString(2)), request.getInt(3))
                            val target = InetSocketAddress(InetAddress.getByName(request.getString(4)), request.getInt(5))
                            val manager = context.getSystemService(ConnectivityManager::class.java)
                            val uid = manager.getConnectionOwnerUid(protocol, source, target)
                            if (uid == Process.INVALID_UID || uid == Process.myUid()) "" else {
                                // Shared UIDs are ambiguous: destination rules are safer than guessing.
                                context.packageManager.getPackagesForUid(uid)?.singleOrNull()?.takeUnless { it in browsers } ?: ""
                            }
                        } catch (_: Exception) { "" }
                        bridge.Bridge.setPackageLookupResult(id, name)
                    }
                } catch (_: Exception) { /* Core stop closes the pipe. */ }
            }
        }, "SSRVPN-package-lookup").apply { isDaemon = true; start() }
    }
}
