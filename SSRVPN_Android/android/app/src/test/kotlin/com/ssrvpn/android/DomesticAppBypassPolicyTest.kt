package com.ssrvpn.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DomesticAppBypassPolicyTest {
    @Test
    fun `curated list covers representative domestic app categories`() {
        val packages = DomesticAppBypassPolicy.packageNames

        assertTrue(packages.contains("com.ss.android.ugc.aweme"))
        assertTrue(packages.contains("com.tencent.mm"))
        assertTrue(packages.contains("com.eg.android.AlipayGphone"))
        assertTrue(packages.contains("com.icbc"))
        assertTrue(packages.contains("com.sankuai.meituan"))
        assertTrue(packages.contains("com.taobao.taobao"))
        assertTrue(packages.contains("com.netease.cloudmusic"))
        assertTrue(packages.contains("tv.danmaku.bili"))
        assertTrue(packages.contains("com.tencent.nrc"))
        assertTrue(packages.contains("com.xiaomi.smarthome"))
    }

    @Test
    fun `foreign browser and privileged tooling packages stay on VPN`() {
        val packages = DomesticAppBypassPolicy.packageNames
        val mustStayOnVpn = setOf(
            "app.nicegram",
            "bin.mt.plus",
            "com.anthropic.claude",
            "com.google.android.youtube",
            "com.microsoft.emmx",
            "com.openai.chatgpt",
            "com.quark.browser",
            "com.rezvorck.tiktokplugin",
            "com.sukisu.ultra",
            "com.twitter.android",
            "com.zhiliaoapp.musically",
            "io.github.a13e300.ksuwebui",
            "li.songe.gkd",
            "moe.shizuku.privileged.api",
            "org.lsposed.manager",
            "org.telegram.messenger.web"
        )

        mustStayOnVpn.forEach { packageName ->
            assertFalse("$packageName must continue through the VPN", packages.contains(packageName))
        }
    }

    @Test
    fun `private and uncertain phone packages are not shipped in public policy`() {
        val packages = DomesticAppBypassPolicy.packageNames
        val privateOrUncertain = setOf(
            "com.ecology.view",
            "com.luckin.shield",
            "com.lucky.luckyemployee",
            "com.nthucc.app",
            "com.yuexin.panel",
            "com.yxt.phoenix.custom"
        )

        privateOrUncertain.forEach { packageName ->
            assertFalse("$packageName must not be embedded", packages.contains(packageName))
        }
    }

    @Test
    fun `policy applies only packages accepted as installed`() {
        val accepted = setOf(
            "com.ss.android.ugc.aweme",
            "com.tencent.mm"
        )

        val applied = DomesticAppBypassPolicy.applyInstalled { packageName ->
            packageName in accepted
        }

        assertEquals(accepted.toList().sorted(), applied)
    }

    @Test
    fun `unexpected application failure is propagated`() {
        assertThrows(IllegalStateException::class.java) {
            DomesticAppBypassPolicy.applyInstalled {
                throw IllegalStateException("builder failure")
            }
        }
    }

    @Test
    fun `package list is unique and deterministic`() {
        val packages = DomesticAppBypassPolicy.packageNames

        assertEquals(packages.distinct(), packages)
        assertEquals(packages.sorted(), packages)
    }

    @Test
    fun `manifest visibility packages stay synchronized with policy`() {
        val manifest = findAndroidManifest()
        val source = manifest.readText()
        val queryBlock = source.substringAfter("<!-- domestic-app-bypass:start -->")
            .substringBefore("<!-- domestic-app-bypass:end -->")
        val visiblePackages = Regex("""<package android:name="([^"]+)"\s*/>""")
            .findAll(queryBlock)
            .map { it.groupValues[1] }
            .toList()

        assertEquals(DomesticAppBypassPolicy.packageNames, visiblePackages)
    }

    private fun findAndroidManifest(): File {
        val relativePaths = listOf(
            "app/src/main/AndroidManifest.xml",
            "SSRVPN_Android/android/app/src/main/AndroidManifest.xml"
        )
        val workingDirectory = requireNotNull(System.getProperty("user.dir"))
        return generateSequence(File(workingDirectory)) { it.parentFile }
            .flatMap { directory -> relativePaths.asSequence().map { File(directory, it) } }
            .firstOrNull { it.isFile }
            ?: error("Unable to locate AndroidManifest.xml")
    }
}
