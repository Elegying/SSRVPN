import 'dart:io';
import 'dart:async';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_settings_page.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/models/site_diagnostic_report.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_view.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_site_diagnostic_result.dart';

class _SettingsCore extends Fake implements ClashServiceBase {
  final result = Completer<String>();
  var requests = 0;
  @override
  void addStatusListener(void Function() listener) {}
  @override
  void removeStatusListener(void Function() listener) {}
  @override
  bool get isRunning => false;
  @override
  Future<String> checkRuleUpdates() {
    requests++;
    return result.future;
  }
}

void main() {
  testWidgets(
      'compact subscription and diagnostic report remain readable on a phone',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final screenshotDir = Platform.environment['SSRVPN_SCREENSHOT_DIR'];
    if (screenshotDir != null) {
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      if (flutterRoot != null) {
        final icons = File(
            '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
        if (icons.existsSync()) {
          final loader = FontLoader('MaterialIcons')
            ..addFont(
                Future.value(ByteData.sublistView(icons.readAsBytesSync())));
          await loader.load();
        }
      }
      final font = File('/System/Library/Fonts/STHeiti Medium.ttc');
      if (font.existsSync()) {
        final loader = FontLoader('FeedbackCJK')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
      }
    }
    final boundary = GlobalKey();
    Widget host(Widget child) => MaterialApp(
        theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: screenshotDir == null ? null : 'FeedbackCJK')),
        home: RepaintBoundary(key: boundary, child: Scaffold(body: child)));
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(SsrvpnSubscriptionView(
      subscriptions: [
        Subscription(id: 'sample', name: '示例订阅', url: 'https://example.com/sub')
      ],
      urlController: controller,
      isAdding: false,
      isRefreshing: false,
      isBusy: false,
      refreshMessage: null,
      refreshMessageColor: null,
      onAdd: () {},
      onRefresh: () {},
      onCancelRefresh: () {},
      onDelete: (_) {},
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('示例订阅').hitTestable(), findsOneWidget);
    Future<void> capture(String name) async {
      if (screenshotDir == null) return;
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(screenshotDir).create(recursive: true);
        await File('$screenshotDir/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('subscriptions');
    await tester.pumpWidget(host(const SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: SsrvpnSiteDiagnosticResult(
            report: SiteDiagnosticReport(
                host: 'example.com',
                summary: '连接失败',
                failure: SiteFailure.connection,
                route: SiteRouteEvidence(
                    rule: 'DomainSuffix example.com',
                    chain: ['香港节点', 'PROXY']))))));
    await tester.pumpAndSettle();
    expect(find.textContaining('代理 → 香港节点'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture('diagnostic');
    expect(find.text('暂时无法访问'), findsOneWidget);
    final core = _SettingsCore();
    await tester.pumpWidget(host(SsrvpnSettingsPage(
        settings: AppSettings(glassEffectLevel: GlassEffectLevel.none),
        core: core,
        dataDirectory: '/tmp',
        onAppearanceChanged: (
            {glassEffectLevel,
            backgroundStyle,
            customBackgroundPath,
            dynamicBackground}) async {},
        onPortChanged: (_) async {},
        checkForUpdate: () async => null,
        onUpdateFound: (_) {})));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await capture('settings');
    await tester.scrollUntilVisible(find.text('检查规则更新'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('检查规则更新'));
    await tester.pump();
    await tester.tap(find.text('检查规则更新'));
    expect(core.requests, 1);
    core.result.complete('规则更新完成，下次连接生效');
    await tester.pumpAndSettle();
    expect(find.text('规则更新完成，下次连接生效'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
