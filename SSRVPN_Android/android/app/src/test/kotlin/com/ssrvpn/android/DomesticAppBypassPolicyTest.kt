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
    fun `requested domestic packages are all included`() {
        val packages = DomesticAppBypassPolicy.packageNames
        val requestedAdditions = setOf(
            "air.tv.douyu.android",
            "bubei.tingshu",
            "chuxin.shimo.shimowendang",
            "cmccwm.mobilemusic",
            "cn.com.cmbc.newmbank",
            "cn.com.langeasy.LangEasyLexis",
            "cn.com.spdb.mobilebank.per",
            "cn.kuwo.player",
            "cn.samsclub.app",
            "cn.soulapp.android",
            "cn.xuexi.android",
            "cn.yonghui.hyd",
            "com.MobileTicket",
            "com.Qunar",
            "com.able.wisdomtree",
            "com.ai.obc.cbn.app",
            "com.alibaba.android.rimet",
            "com.alibaba.wireless",
            "com.android.bankabc",
            "com.antfortune.wealth",
            "com.baidu.BaiduMap",
            "com.baidu.tieba",
            "com.bankcomm.Bankcomm",
            "com.bilibili.comic",
            "com.cainiao.wireless",
            "com.cctv.yangshipin.app.androidp",
            "com.cebbank.mobile.cemb",
            "com.chaoxing.mobile",
            "com.chinamworld.bocmbci",
            "com.cmcc.cmvideo",
            "com.dianping.v1",
            "com.didapinche.booking",
            "com.douban.frodo",
            "com.dragon.read",
            "com.duowan.kiwi",
            "com.eastmoney.android.berlin",
            "com.eastmoney.android.fund",
            "com.ecitic.bank.mobile",
            "com.fcbox.hivebox",
            "com.fenbi.android.leo",
            "com.fenbi.android.solar",
            "com.greenpoint.android.mc10086.activity",
            "com.handsgo.jiakao.android",
            "com.hunantv.imgo.activity",
            "com.hupu.games",
            "com.ifeng.news2",
            "com.jd.jrapp",
            "com.jingdong.pdj",
            "com.jingyao.easybike",
            "com.kmxs.reader",
            "com.kuaikan.comic",
            "com.kuaishou.nebula",
            "com.kugou.android",
            "com.lanjinger.choiassociatedpress",
            "com.lphtsccft",
            "com.mcdonalds.gma.cn",
            "com.mxbc.mxsa",
            "com.netease.newsreader.activity",
            "com.nowcasting.activity",
            "com.qidian.QDReader",
            "com.qiyi.video",
            "com.qiyi.video.lite",
            "com.sdu.didi.psnger",
            "com.sf.activity",
            "com.sgcc.wsgw.cn",
            "com.shizhuang.duapp",
            "com.sina.weibolite",
            "com.sinovatech.unicom.ui",
            "com.smzdm.client.android",
            "com.sohu.sohuvideo",
            "com.ss.android.article.news",
            "com.ss.android.article.video",
            "com.ss.android.ugc.aweme.lite",
            "com.tencent.docs",
            "com.tencent.karaoke",
            "com.tencent.news",
            "com.tencent.qqlive",
            "com.tencent.qqmusic",
            "com.tencent.tim",
            "com.tencent.wemeet.app",
            "com.tencent.weread",
            "com.tmall.wireless",
            "com.umetrip.android.msky.app",
            "com.unionpay",
            "com.wm.dmall",
            "com.wondertek.paper",
            "com.wuba",
            "com.wuba.zhuanzhuan",
            "com.wudaokou.hippo",
            "com.xiaomi.youpin",
            "com.ximalaya.ting.android",
            "com.ximalaya.ting.lite",
            "com.xueqiu.android",
            "com.yek.android.kfc.activitys",
            "com.yitong.mbank.psbc",
            "com.youku.phone",
            "com.yuque.mobile.android.app",
            "com.zhihu.android",
            "com.zuoyebang.knowledge",
            "ctrip.android.view",
            "tv.acfundanmaku.video",
            "tv.danmaku.bilibilihd"
        )

        assertEquals(102, requestedAdditions.size)
        assertEquals(176, packages.size)
        requestedAdditions.forEach { packageName ->
            assertTrue("$packageName must bypass the VPN", packages.contains(packageName))
        }
    }

    @Test
    fun `selected foreign browser email cloud and privileged packages stay on VPN`() {
        val packages = DomesticAppBypassPolicy.packageNames
        val mustStayOnVpn = setOf(
            "app.nicegram",
            "bin.mt.plus",
            "com.anthropic.claude",
            "com.google.android.youtube",
            "com.microsoft.emmx",
            "com.openai.chatgpt",
            "com.UCMobile",
            "com.android.browser",
            "com.baidu.browser.apps",
            "com.baidu.searchbox",
            "com.estrongs.android.pop",
            "com.hihonor.appmarket",
            "com.huawei.appmarket",
            "com.huawei.browser",
            "com.intsig.camscanner",
            "com.netease.mail",
            "com.netease.mobimail",
            "com.oray.sunlogin",
            "com.qihoo.browser",
            "com.quark.browser",
            "com.rezvorck.tiktokplugin",
            "com.sukisu.ultra",
            "com.tencent.androidqqmail",
            "com.tencent.mtt",
            "com.twitter.android",
            "com.vivo.browser",
            "com.xunlei.downloadprovider",
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
