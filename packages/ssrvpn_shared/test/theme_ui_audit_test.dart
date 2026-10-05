import 'package:ssrvpn_shared/widgets/ssrvpn_cloud_art.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_theme_icon.dart';
import 'dart:io';
import 'package:ssrvpn_shared/services/node_pin_store.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_settings_page.dart';

class _Core extends Fake implements ClashServiceBase {
  @override
  bool get isRunning => false;
  @override
  void addStatusListener(VoidCallback listener) {}
  @override
  void removeStatusListener(VoidCallback listener) {}
}

class _AuditPins extends NodePinStore {
  _AuditPins() : super('/unused-audit-pins');
  @override
  Future<void> load() async {}
}

void main() {
  final directory = Platform.environment['SSRVPN_UI_CAPTURE_DIR'];
  setUpAll(() async {
    if (directory == null) return;
    for (final entry in {
      'AuditChinese': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons': 'build/unit_test_assets/fonts/MaterialIcons-Regular.otf'
    }.entries) {
      final loader = FontLoader(entry.key);
      loader
          .addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  for (final variant in AppThemeVariant.values) {
    for (final viewport in [
      const Size(390, 844),
      const Size(460, 840),
      const Size(355, 648),
      const Size(320, 568),
      const Size(1000, 760),
      const Size(712, 1067),
      const Size(1067, 712)
    ]) {
      testWidgets('${variant.name} pages and menus ${viewport.width}',
          (tester) async {
        final previousShadows = debugDisableShadows;
        debugDisableShadows = false;
        try {
          tester.view.physicalSize = viewport;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final captureKey = GlobalKey();
          final settings = AppSettings(themeVariant: variant);
          final node = ProxyNode(
              name: '私家车 · 日本东京',
              type: 'ss',
              server: 'example.com',
              port: 443,
              group: '我的订阅');
          final sub = Subscription(
              id: 'sample', name: '我的订阅', url: 'https://example.com/sub');
          final input = TextEditingController();
          addTearDown(input.dispose);
          Widget host(Widget body, int tab) => MaterialApp(
              theme: ThemeData.dark().copyWith(
                  textTheme: directory == null
                      ? null
                      : ThemeData.dark()
                          .textTheme
                          .apply(fontFamily: 'AuditChinese')),
              builder: (context, child) => SsrvpnAppearanceScope(
                  settings: settings,
                  child: RepaintBoundary(key: captureKey, child: child!)),
              home: Scaffold(
                  body: SsrvpnAppBackdrop(
                      child: SsrvpnHomeShell(
                          body: body,
                          navigation: SsrvpnBottomNavigation(
                              currentIndex: tab,
                              version: '5.0.35-test',
                              onTap: (_) {})))));
          Future<void> shot(String name) async {
            await tester.runAsync(() async {
              for (final provider in <ImageProvider>[
                if (variant != AppThemeVariant.soft)
                  AssetImage(SsrvpnTheme(variant).wallpaper,
                      package: 'ssrvpn_shared'),
                if (variant == AppThemeVariant.defaultTheme)
                  const AssetImage(
                      'assets/themes/default-subscription-header.webp',
                      package: 'ssrvpn_shared'),
                if (variant != AppThemeVariant.defaultTheme)
                  for (final name in SsrvpnThemeIcon.names)
                    AssetImage('assets/themes/${variant.name}-$name.webp',
                        package: 'ssrvpn_shared'),
                if (variant == AppThemeVariant.cloud)
                  for (final name in [
                    'hero',
                    'power',
                    'home',
                    'subscription',
                    'settings',
                    'upload',
                    'download',
                    'total',
                    'devices'
                  ])
                    AssetImage('assets/themes/cloud-$name.webp',
                        package: 'ssrvpn_shared'),
                if (variant != AppThemeVariant.defaultTheme &&
                    variant != AppThemeVariant.cloud &&
                    variant != AppThemeVariant.aurora &&
                    variant != AppThemeVariant.dusk &&
                    variant != AppThemeVariant.soft)
                  AssetImage('assets/themes/${variant.name}-control.webp',
                      package: 'ssrvpn_shared'),
                if (SsrvpnTheme(variant).isIllustrated)
                  for (final name in ['public-ip', 'system-proxy', 'tun'])
                    AssetImage('assets/themes/${variant.name}-$name.webp',
                        package: 'ssrvpn_shared'),
                if (variant == AppThemeVariant.pixel)
                  const AssetImage('assets/themes/pixel-country-JP.webp',
                      package: 'ssrvpn_shared'),
                for (final v in AppThemeVariant.values)
                  ResizeImage(
                      AssetImage(SsrvpnTheme(v).icon, package: 'ssrvpn_shared'),
                      width: 128)
              ]) {
                await precacheImage(provider, captureKey.currentContext!);
              }
            });
            // Build newly pushed routes before advancing their entrance animation.
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pump();
            expect(tester.takeException(), isNull);
            if (directory == null) return;
            final boundary = captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final data =
                  await image.toByteData(format: ui.ImageByteFormat.png);
              await Directory(directory).create(recursive: true);
              await File(
                      '$directory/${variant.name}-${viewport.width.toInt()}-$name.png')
                  .writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }

          var toggles = 0;
          await tester.pumpWidget(host(
              SsrvpnHomeOverview(
                  isConnected: true,
                  isConnecting: false,
                  selectedNode: node,
                  selectedLatency: 30,
                  publicIpv4: '203.0.113.28',
                  onEnableTunChanged: (_) {},
                  selectedCountryCode: 'JP',
                  onToggleConnection: () => toggles++,
                  onOpenNodes: () {},
                  onShowAbout: () {},
                  onShowTutorial: () {},
                  onShowLogs: () {},
                  onRefreshPublicIp: () {},
                  bottomContent: SsrvpnHomeTrafficPanel(
                      active: false,
                      connected: true,
                      readSample: () async => null,
                      accountUsage: const AccountUsage(
                          usedBytes: 134217728000,
                          trafficLimitBytes: 268435456000,
                          onlineDevices: 2,
                          deviceLimit: 3,
                          serverTime: 1,
                          trafficObservedAt: 1,
                          onlineObservedAt: 1,
                          expiresAt: 31))),
              0));
          await shot('home');
          expect(find.text('点击断开连接'), findsNothing);
          final powerRect = tester
              .getRect(find.byKey(const Key('ssrvpn-power-button')).first);
          expect(powerRect.center.dx, closeTo(viewport.width / 2, .5),
              reason:
                  'Connection button must stay centered independently of scenery');
          if (variant == AppThemeVariant.cloud) {
            final scene = tester.getRect(find.byType(SsrvpnCloudHero));
            expect(scene.width, closeTo(viewport.width, .5),
                reason: 'Tablet scenery must not inherit the card width limit');
            expect(powerRect.top, greaterThanOrEqualTo(scene.top));
            expect(powerRect.bottom, lessThanOrEqualTo(scene.bottom));
          }
          final ringRect =
              tester.getRect(find.byKey(const Key('account-usage-ring')));
          final navRect = tester
              .getRect(find.byKey(const Key('ssrvpn-bottom-navigation')).first);
          for (final key in [
            'ssrvpn-current-node-card',
            'home-public-ip',
            'home-traffic-panel'
          ]) {
            final panel = tester.getRect(find.byKey(Key(key)).first);
            expect(panel.left, closeTo(navRect.left, 1),
                reason: '$key left edge aligns with navigation');
            expect(panel.right, closeTo(navRect.right, 1),
                reason: '$key right edge aligns with navigation');
          }
          final proxy =
              tester.getRect(find.byKey(const Key('home-system-proxy')));
          final tun = tester.getRect(find.byKey(const Key('home-tun-mode')));
          expect(proxy.left, closeTo(navRect.left, 1));
          expect(tun.right, closeTo(navRect.right, 1));
          final nodeRect =
              tester.getRect(find.byKey(const Key('ssrvpn-current-node-card')));
          expect(proxy.bottom, lessThan(nodeRect.top));
          expect(tun.bottom, closeTo(proxy.bottom, .5));
          expect(powerRect.bottom, lessThanOrEqualTo(proxy.top));
          final ipRect =
              tester.getRect(find.byKey(const Key('home-public-ip')));
          final statsRect =
              tester.getRect(find.byKey(const Key('home-traffic-panel')));
          final gap = ipRect.top - nodeRect.bottom;
          expect(statsRect.top - ipRect.bottom, closeTo(gap, 1));
          expect(navRect.top - statsRect.bottom, closeTo(gap, 1));
          expect(ringRect.bottom, lessThanOrEqualTo(navRect.top),
              reason: 'Account gauge must be on the first screen');
          expect(ringRect.top, greaterThanOrEqualTo(0));
          if (variant != AppThemeVariant.defaultTheme) {
            expect(
                find.ancestor(
                    of: find.byKey(const Key('ssrvpn-power-button')),
                    matching: find.byType(Scrollable)),
                findsNothing);
          }

          // The themed live control must remain an actual disconnect action.
          await tester.tap(find.byKey(const Key('ssrvpn-power-button')).first);
          expect(toggles, 1);
          await tester.pumpWidget(host(
              SsrvpnNodeSelectionPage(
                  preferenceDirectory: '/unused-audit-pins',
                  pinStoreFactory: (_) => _AuditPins(),
                  nodesOf: () => [
                        node,
                        ProxyNode(
                            name: '美国洛杉矶',
                            type: 'ss',
                            server: 'example.org',
                            port: 443,
                            group: '我的订阅')
                      ],
                  selectedNodeNameOf: () => node.name,
                  proxyModeOf: () => ProxyMode.rule,
                  testingNodeNameOf: () => null,
                  isBatchTestingOf: () => false,
                  isConnectingOf: () => false,
                  countryCodeOf: (_) => 'JP',
                  latencyOf: (_) => 30,
                  onClose: () {},
                  onRefresh: () async {},
                  onTestAll: () async {},
                  onTestLatency: (_) async {},
                  onSelectNode: (_) async {},
                  onProxyModeChanged: (_) async {},
                  onShowForceProxySites: () {},
                  onShowForceDirectSites: () {}),
              0));
          await shot('nodes');
          await tester.tap(find.text('全部订阅'));
          await shot('node-menu');
          Navigator.of(tester.element(find.text('选择订阅'))).pop();
          await tester.pumpAndSettle();
          await tester.pumpWidget(host(
              SsrvpnSubscriptionView(
                  subscriptions: [sub],
                  urlController: input,
                  isAdding: false,
                  isRefreshing: false,
                  isBusy: false,
                  refreshMessage: null,
                  refreshMessageColor: null,
                  onAdd: () {},
                  onRefresh: () {},
                  onCancelRefresh: () {},
                  onDelete: (_) {},
                  onEdit: (_) {},
                  onShowLogs: () {}),
              1));
          await shot('subscriptions');
          final context = tester.element(find.byType(SsrvpnSubscriptionView));
          showSsrvpnSubscriptionEditDialog(context, sub);
          await shot('edit-dialog');
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          await tester.pumpWidget(host(
              SsrvpnSettingsPage(
                  settings: settings,
                  core: _Core(),
                  onAppearanceChanged: ({themeVariant}) async {},
                  onPortChanged: (_) async {},
                  checkForUpdate: () async => null,
                  onUpdateFound: (_) {}),
              2));
          await shot('settings');
          await tester.scrollUntilVisible(find.text('网站访问诊断'), 200,
              scrollable: find.byType(Scrollable).first);
          await shot('settings-tools');
          final diagnosticTile = find.ancestor(
              of: find.text('网站访问诊断'), matching: find.byType(ListTile));
          expect(
              find.descendant(
                  of: diagnosticTile,
                  matching: find.byWidgetPredicate(
                      (w) => w is SsrvpnThemeIcon && w.name == 'diagnostic')),
              findsOneWidget);
          await tester.tap(find.text('网站访问诊断'));
          await shot('site-diagnostic');
          expect(find.byKey(const Key('ssrvpn-site-diagnostic-input')),
              findsOneWidget);
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        } finally {
          debugDisableShadows = previousShadows;
        }
      });
    }
  }
}
