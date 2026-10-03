import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/app_diagnostics_view.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_node_selection_page.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_edit_dialog.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_view.dart';

void main() {
  final captureFont = Platform.environment['SSRVPN_UI_CAPTURE_FONT'];
  setUpAll(() async {
    if (captureFont == null) return;
    for (final entry in {
      'AuditChinese': captureFont,
      'MaterialIcons': 'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(File(entry.value)
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)));
      await loader.load();
    }
  });
  final captureKey = GlobalKey();
  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['SSRVPN_UI_CAPTURE_DIR'];
    if (directory == null) return;
    await tester.pump();
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File('$directory/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  final subscription = Subscription(
    id: 'audit',
    name: '界面测试订阅',
    url: 'https://example.com/subscription',
  );

  Widget host(Widget child, {double scale = 3.2, double keyboard = 0}) =>
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          textTheme: captureFont == null
              ? null
              : ThemeData.dark().textTheme.apply(fontFamily: 'AuditChinese'),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQueryData(
              size: const Size(320, 568),
              textScaler: TextScaler.linear(scale),
              viewInsets: EdgeInsets.only(bottom: keyboard)),
          child: SsrvpnAppearanceScope(
            settings: AppSettings(themeVariant: AppThemeVariant.aurora),
            child: RepaintBoundary(key: captureKey, child: child!),
          ),
        ),
        home: Scaffold(body: child),
      );

  testWidgets('populated subscriptions fit maximum text on narrow screens',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(SsrvpnSubscriptionView(
      subscriptions: [subscription],
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
      onEdit: (_) {},
    )));
    await tester.scrollUntilVisible(find.byTooltip(subscription.name), 150,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
    final name =
        tester.renderObject<RenderParagraph>(find.text(subscription.name));
    expect(
        name.getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1)),
        isNotEmpty,
        reason:
            'The visible name must retain text rather than only an ellipsis');
    await capture(tester, 'subscriptions-large-text');
  });

  testWidgets('subscription edit remains usable above keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(
        Builder(
            builder: (context) => TextButton(
                  onPressed: () =>
                      showSsrvpnSubscriptionEditDialog(context, subscription),
                  child: const Text('编辑'),
                )),
        scale: 3.2,
        keyboard: 300));
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('取消'), findsOneWidget);
    await capture(tester, 'subscription-edit-keyboard');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('repeated edit activation opens only one owned dialog',
      (tester) async {
    await tester.pumpWidget(host(
        Builder(
            builder: (context) => TextButton(
                  onPressed: () =>
                      showSsrvpnSubscriptionEditDialog(context, subscription),
                  child: const Text('编辑'),
                )),
        scale: 1));
    final activate = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '编辑'))
        .onPressed!;
    activate();
    activate();
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('ssrvpn-subscription-edit-glass'),
            skipOffstage: false),
        findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    activate();
    await tester.pumpAndSettle();
    expect(find.text('编辑订阅'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('subscription picker fits maximum text without changing nodes',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = ProxyNode(
        name: '测试节点',
        type: 'ss',
        server: 'example.com',
        port: 443,
        group: '测试订阅');
    await tester.pumpWidget(host(SsrvpnNodeSelectionPage(
      nodesOf: () => [node],
      selectedNodeNameOf: () => node.name,
      proxyModeOf: () => ProxyMode.rule,
      testingNodeNameOf: () => null,
      isBatchTestingOf: () => false,
      isConnectingOf: () => false,
      countryCodeOf: (_) => 'US',
      latencyOf: (_) => null,
      onClose: () {},
      onRefresh: () async {},
      onTestAll: () async {},
      onTestLatency: (_) async {},
      onSelectNode: (_) async {},
      onProxyModeChanged: (_) async {},
    )));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('全部订阅'));
    await tester.pumpAndSettle();
    final openPicker = tester
        .widget<InkWell>(find
            .ancestor(of: find.text('全部订阅'), matching: find.byType(InkWell))
            .first)
        .onTap!;
    openPicker();
    openPicker();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
        find.byKey(const Key('ssrvpn-subscription-picker-glass'),
            skipOffstage: false),
        findsOneWidget);
    expect(find.text('选择订阅'), findsOneWidget);
    await capture(tester, 'subscription-picker-large-text');
    // Close the picker only; never invoke a node or network action.
    final context = tester.element(find.text('选择订阅'));
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    openPicker();
    await tester.pumpAndSettle();
    expect(find.text('选择订阅'), findsOneWidget);
    Navigator.of(tester.element(find.text('选择订阅'))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('diagnostic report scrolls in a compact large-text panel',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(SizedBox(
      height: 240,
      child: AppDiagnosticsView(
        runDiagnostics: () async => AppDiagnosticReport(
            generatedAt: DateTime.utc(2026, 10, 2),
            checks: const [
              AppDiagnosticCheck(
                  id: 'ui-only',
                  title: '界面测试',
                  status: AppDiagnosticStatus.warning,
                  summary: '合成诊断结果')
            ]),
        loadHistory: () async => [],
        repair: (_) async =>
            const AppRepairResult(success: false, message: 'unused'),
      ),
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.text('复制报告')).width, greaterThan(100),
        reason:
            'Diagnostic actions must respect the requested large text size');
    await tester.scrollUntilVisible(find.text('合成诊断结果'), 100);
    expect(find.text('合成诊断结果'), findsOneWidget);
    await capture(tester, 'diagnostic-compact-report');
  });

  testWidgets('adding subscription exposes a named progress state',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(
          SsrvpnSubscriptionView(
            subscriptions: const [],
            urlController: controller,
            isAdding: true,
            isRefreshing: false,
            isBusy: true,
            refreshMessage: null,
            refreshMessageColor: null,
            onAdd: () => fail('Busy add must stay disabled'),
            onRefresh: () {},
            onCancelRefresh: () {},
            onDelete: (_) {},
          ),
          scale: 1));
      expect(
          tester
              .getSemantics(find.byKey(const Key('ssrvpn-subscription-add')))
              .getSemanticsData()
              .label,
          contains('添加'));
      expect(
          tester
              .widget<FilledButton>(
                  find.byKey(const Key('ssrvpn-subscription-add')))
              .onPressed,
          isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('diagnostic failure stays scrollable at maximum text size',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(SizedBox(
      height: 240,
      child: AppDiagnosticsView(
        runDiagnostics: () async => throw StateError('UI-only failure'),
        loadHistory: () async => [],
        repair: (_) async =>
            const AppRepairResult(success: false, message: 'unused'),
      ),
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('重试'), 100);
    expect(find.text('重试').hitTestable(), findsOneWidget);
    await capture(tester, 'diagnostic-failure-large-text');
  });
}
