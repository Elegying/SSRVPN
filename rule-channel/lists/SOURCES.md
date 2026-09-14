# 应用名单补充来源

核对日期：2026-09-14 至 2026-09-15。此次只补充精确 Android 包名，不导入第三方订阅、域名规则、桌面进程名或正则。两份名单组件版本从 1.0.0 提升为 1.0.1。

## 国内名单

候选来自 [mnixry/direct-android-ruleset](https://github.com/mnixry/direct-android-ruleset)，截至核对时未归档，rules 分支 9 月 12、13、14 日均有自动提交。固定核对 [2026-09-14 的 APP.mutated.yaml](https://github.com/mnixry/direct-android-ruleset/blob/616d9c137effef68132efb8150e2895a36996b46/@Merged/APP.mutated.yaml)。该项目声明 AGPL-3.0；此处保留其事实核对来源与署名，不引入生成程序。

从中人工挑选明确面向国内服务的 23 项包名，未整库同步。应用市场收录不等于适合直连，上游还包含厂商整组匹配、国际版应用等，不予照搬。应用宝网页此次未返回可读详情，以下名称与包名以固定上游记录为依据，未宣称全部通过官方商店或实机复核。

| 应用 | 包名 |
| --- | --- |
| 曹操出行 | `cn.caocaokeji.user` |
| 大麦 | `cn.damai` |
| 唯品会 | `com.achievo.vipshop` |
| 安居客 | `com.anjuke.android.app` |
| 兴业银行 | `com.cib.cibmb` |
| 兴业生活 | `com.cib.xyk` |
| 全民生活 | `com.cmbc.cc.mbank` |
| 掌上生活 | `com.cmbchina.ccd.pluto.cmbActivity` |
| Keep - AI 运动教练 | `com.gotokeep.keep` |
| 链家 | `com.homelink.android` |
| 首汽约车 | `com.ichinait.gbpassenger` |
| 前程无忧51Job | `com.job.android` |
| 货拉拉 | `com.lalamove.huolala.client` |
| 贝壳找房 | `com.lianjia.beike` |
| 平安好车主 | `com.pingan.carowner` |
| 平安金管家 | `com.pingan.lifeinsurance` |
| 平安口袋银行 | `com.pingan.paces.ccms` |
| 猫眼 | `com.sankuai.movie` |
| 苏宁易购 | `com.suning.mobile.ebuy` |
| 同程旅行 | `com.tongcheng.android` |
| 叮咚买菜 | `com.yaya.zone` |
| 智行火车票 | `com.yipiao` |
| 智联招聘 | `com.zhaopin.social` |

## 国外名单

未找到同时满足独立 Android 包名合集、长期持续维护和可直接采用分流语义的统一国外名单。[blackmatrix7/ios_rule_script](https://github.com/blackmatrix7/ios_rule_script) 仍在维护，但主要是域名/IP 规则，少量 PROCESS-NAME 混有桌面进程和系统组件，适合作为参考，不直接整库导入。

Google Play 包名由其 [Google 规则](https://github.com/blackmatrix7/ios_rule_script/blob/master/rule/Clash/Google/Google.yaml) 与上述国内项目的排除配置交叉确认。其他六项分别核对 Google Play 上开发者提供的应用页面；包名可以直接用于 `https://play.google.com/store/apps/details?id=包名` 查看来源。

| 应用 | 包名 |
| --- | --- |
| Google Play 商店 | `com.android.vending` |
| Proton Mail | `ch.protonmail.android` |
| LINE | `jp.naver.line.android` |
| SoundCloud | `com.soundcloud.android` |
| Google 文档 | `com.google.android.apps.docs.editors.docs` |
| Google 表格 | `com.google.android.apps.docs.editors.sheets` |
| Google 幻灯片 | `com.google.android.apps.docs.editors.slides` |

Google 服务框架、Play 服务等系统组件未随本次扩充加入。通用浏览器继续按访问目标分流。采用 PROXY 表示本项目的默认应用策略，不表示该应用所有目标在所有网络均被封锁。

## 验证与发布

本次源名单校验通过：直连 205 项、代理 39 项，互斥、无重复、无通用浏览器。发布器 4 项测试通过，项目真实 macOS 内核 `-t` 接受全部 244 条 PROCESS-NAME 规则；这属于语法与加载检查，不能代替 Android 实机分应用流量测试。

使用现有发布器校验精确包名、排序、重复、两份名单互斥和浏览器排除。此次仅修改名单源文件，未改动已签名的内置快照、在线 latest 或历史 snapshots；需由既有签名发布流程生成更高快照版本后，客户端才能下载，新的内置快照也应由同一流程生成。不得直接修改旧 manifest 哈希或签名。没有新增定时全量导入第三方应用名单的机制。
