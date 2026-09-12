import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'account_usage_test.dart' show usageJson, usageNode;

void main() {
  final reports = <Map<String, dynamic>>[];
  const screenshotDirectory = String.fromEnvironment('SSRVPN_LAYOUT_OUTPUT');
  const iconPath = String.fromEnvironment('SSRVPN_LAYOUT_ICONS');
  const fontPath = String.fromEnvironment('SSRVPN_LAYOUT_FONT');
  setUpAll(() async {
    if (iconPath.isNotEmpty) {
      final icons = FontLoader('MaterialIcons');
      icons.addFont(File(iconPath)
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)));
      await icons.load();
    }
    if (fontPath.isNotEmpty) {
      final loader = FontLoader('UsageEvidence');
      loader.addFont(File(fontPath)
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)));
      await loader.load();
    }
  });
  for (final size in [
    const Size(320, 568),
    const Size(453, 594),
    const Size(488, 640),
    const Size(
        380, 520), // Windows minimum 380x560 minus existing 40px titlebar.
    const Size(380, 532), // macOS minimum minus existing 28px titlebar.
    const Size(844, 390),
    for (var width = 400.0; width <= 960; width += 40) Size(width, 520),
    const Size(320, 640),
    const Size(360, 640),
    const Size(390, 844),
    const Size(380, 560),
    const Size(440, 720),
    const Size(800, 600),
    const Size(640, 320)
  ]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final error in [false, true]) {
        testWidgets('whole home $size scale $scale error $error 3-5-3',
            (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          var toggles = 0, navigation = 0;
          final outerNotices = error && size.width == 380 && size.height < 560;
          Widget home(bool five) => MaterialApp(
              theme: ThemeData(
                  fontFamily: fontPath.isEmpty ? null : 'UsageEvidence'),
              home: MediaQuery(
                  data: MediaQueryData(
                      size: size,
                      padding: size.width <= 390 && size.width != 380
                          ? const EdgeInsets.only(top: 24, bottom: 24)
                          : EdgeInsets.zero,
                      textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                      body: RepaintBoundary(
                          key: const Key('capture'),
                          child: SsrvpnAppBackdrop(
                              child: SsrvpnHomeShell(
                            notices: outerNotices
                                ? [
                                    const SsrvpnHomeNotice(
                                        icon: Icons.warning_amber,
                                        color: Colors.orange,
                                        title: '安全模式已启用',
                                        message: '托盘、旧窗口位置和 Mihomo 自动初始化已跳过。'),
                                    const SsrvpnHomeNotice(
                                        icon: Icons.error_outline,
                                        color: Colors.red,
                                        title: '部分启动步骤失败',
                                        message:
                                            '代理核心：操作未完成。暂时无法确定具体原因，请查看诊断后重试。'),
                                    const SsrvpnHomeNotice(
                                        icon: Icons.error_outline,
                                        color: Colors.red,
                                        title: '操作未完成',
                                        message:
                                            '连接未完成：本地端口被其他应用占用，已保留原有配置与系统代理恢复状态，请稍后重试连接。'),
                                  ]
                                : const [],
                            body: SsrvpnHomeOverview(
                                isConnected: !outerNotices,
                                isConnecting: false,
                                selectedNode: usageNode(
                                    name: '私家车-非常长的完整节点名称测试-abcdef-123456789'),
                                selectedLatency: 30,
                                selectedCountryCode: 'US',
                                connectionNotice:
                                    outerNotices ? null : '网络待确认，正在重新检查可用性',
                                errorMessage: error && !outerNotices
                                    ? '节点连接失败，请检查网络后重试。若持续失败，可更换节点或打开诊断查看具体原因。'
                                    : null,
                                onToggleConnection: () => toggles++,
                                onOpenNodes: () {},
                                onShowAbout: () {},
                                onShowTutorial: () {},
                                onShowLogs: () {},
                                onRefreshPublicIp: () {},
                                bottomContent: SsrvpnHomeTrafficPanel(
                                    active: false,
                                    connected: true,
                                    accountUsage: five
                                        ? AccountUsage.parse(usageJson(
                                            used: 9223372036854775807,
                                            online: 9223372036854775807))
                                        : null,
                                    readSample: () async => null)),
                            navigation: SsrvpnBottomNavigation(
                                currentIndex: 0,
                                version: '4.0.29',
                                onTap: (_) => navigation++),
                          ))))));
          Rect? first;
          for (final five in [false, true, false]) {
            await tester.pumpWidget(home(five));
            await tester.pump();
            final cards = find.byWidgetPredicate((w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>)
                    .value
                    .startsWith('home-traffic-card-'));
            final nav = tester.getRect(find.byType(SsrvpnBottomNavigation));
            final panel =
                tester.getRect(find.byKey(const Key('home-traffic-panel')));
            final power =
                tester.getRect(find.byKey(const Key('ssrvpn-power-button')));
            final status =
                tester.getRect(find.byKey(const Key('home-connection-status')));
            expect(power.width, closeTo(power.height, .1));
            expect(power.center.dx, closeTo(status.center.dx, .1),
                reason:
                    'Connection button and status must share one centerline');
            final content =
                tester.getRect(find.byKey(const Key('ssrvpn-home-content')));
            if (content.height >= 490 && size.width < 560) {
              expect(power.center.dx, closeTo(content.center.dx, .1));
            }
            final fonts = find
                .descendant(
                    of: find.byType(SsrvpnHomeOverview),
                    matching: find.byType(Text))
                .evaluate()
                .map((e) => (e.widget as Text).style?.fontSize ?? 14)
                .toList();
            final problems = <String>[];
            final boxes = <Rect>[];
            for (final element in cards.evaluate()) {
              final rect = tester.getRect(find.byWidget(element.widget));
              boxes.add(rect);
              if (rect.top < 0 ||
                  rect.bottom > nav.top + .1 ||
                  rect.left < 0 ||
                  rect.right > size.width) {
                problems.add('card outside viewport: $rect');
              }
            }
            final navigationSurface = tester
                .getRect(find.byKey(const Key('ssrvpn-bottom-navigation')));
            expect(boxes.map((r) => r.left).reduce((a, b) => a < b ? a : b),
                closeTo(navigationSurface.left, .1));
            expect(boxes.map((r) => r.right).reduce((a, b) => a > b ? a : b),
                closeTo(navigationSurface.right, .1));
            for (var i = 0; i < boxes.length; i++) {
              for (var j = i + 1; j < boxes.length; j++) {
                if (boxes[i].overlaps(boxes[j])) problems.add('cards overlap');
              }
            }
            // Locate genuine child overflow, including header/details and bottom navigation.
            for (final element in find.byType(Column).evaluate()) {
              final render = element.renderObject;
              if (render is! RenderFlex || !render.hasSize) continue;
              final parent = render.localToGlobal(Offset.zero) & render.size;
              render.visitChildren((child) {
                if (child is RenderBox && child.hasSize) {
                  final rect = child.localToGlobal(Offset.zero) & child.size;
                  if (rect.bottom > parent.bottom + .1) {
                    problems.add(
                        'column overflow ${rect.bottom - parent.bottom}: ${element.toStringShort()} parent=$parent child=$rect');
                  }
                }
              });
            }
            for (final element in cards.evaluate()) {
              final card = tester.getRect(find.byWidget(element.widget));
              for (final text in find
                  .descendant(
                      of: find.byWidget(element.widget),
                      matching: find.byType(RichText))
                  .evaluate()) {
                final render = text.renderObject! as RenderParagraph;
                final rect = render.localToGlobal(Offset.zero) & render.size;
                if (rect.top < card.top ||
                    rect.bottom > card.bottom + .1 ||
                    rect.left < card.left ||
                    rect.right > card.right + .1 ||
                    render.didExceedMaxLines) {
                  problems.add(
                      'card text clipped: ${render.text.toPlainText()} $rect in $card');
                }
              }
            }
            for (final key in [
              'ssrvpn-about-button',
              'ssrvpn-tutorial-button',
              'ssrvpn-current-node-card'
            ]) {
              final rect = tester.getRect(find.byKey(Key(key)));
              if (rect.height < 48 || rect.top < 0 || rect.bottom > nav.top) {
                problems
                    .add('control outside viewport or undersized: $key $rect');
              }
            }
            final exception = tester.takeException();
            if (exception != null) problems.add(exception.toString());
            reports.add({
              'width': size.width,
              'height': size.height,
              'scale': scale,
              'error': error,
              'cards': five ? 5 : 3,
              'minimumFont': fonts.reduce((a, b) => a < b ? a : b),
              'navTop': nav.top,
              'panel': panel.toString(),
              'power': power.toString(),
              'problems': problems
            });
            expect(cards, findsNWidgets(five ? 5 : 3));
            expect(
                find.descendant(
                    of: find.byType(SsrvpnHomeShell),
                    matching: find.byType(Scrollable)),
                findsNothing);
            expect(problems, isEmpty, reason: jsonEncode(reports.last));
            final beforeDrag = tester
                .getRect(find.byKey(const Key('ssrvpn-current-node-card')));
            await tester.drag(find.byKey(const Key('ssrvpn-current-node-card')),
                const Offset(0, -40));
            await tester.pump();
            expect(
                tester
                    .getRect(find.byKey(const Key('ssrvpn-current-node-card'))),
                beforeDrag);
            expect(power.bottom, lessThanOrEqualTo(nav.top));
            expect(power.top, greaterThanOrEqualTo(0));
            if (first == null) {
              first = panel;
            } else if (!five) {
              expect(panel, first);
            }
            await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
            await tester.tap(find.text('订阅').hitTestable().first);
            expect(toggles, greaterThan(0));
            expect(navigation, greaterThan(0));
            await tester.pumpAndSettle();
            if (screenshotDirectory.isNotEmpty &&
                (size.width == 320 ||
                    size.width == 453 ||
                    size.width == 488 ||
                    size.width == 380 ||
                    size == const Size(640, 320) ||
                    size == const Size(390, 844)) &&
                (!error || scale == 2)) {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                  find.byKey(const Key('capture')));
              await tester.runAsync(() async {
                final image = await boundary.toImage(pixelRatio: 2);
                final bytes =
                    await image.toByteData(format: ui.ImageByteFormat.png);
                image.dispose();
                final directory = Directory(screenshotDirectory);
                await directory.create(recursive: true);
                await File(
                        '${directory.path}/${size.width.toInt()}x${size.height.toInt()}-${five ? 'five' : 'three'}-scale$scale-error$error.png')
                    .writeAsBytes(bytes!.buffer.asUint8List());
              });
            }
          }
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
  for (final width in [320.0, 390.0, 440.0, 800.0]) {
    testWidgets('five cards and long device limits stay stable at $width',
        (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      List<Rect>? original;
      for (final count in [
        0,
        9999,
        99950,
        999999,
        999999999,
        9223372036854775807
      ]) {
        final json = usageJson(used: count, online: count);
        (json['data'] as Map<String, dynamic>)['deviceLimit'] = count;
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: Align(
                    alignment: Alignment.bottomCenter,
                    child: SizedBox(
                        height: 110,
                        child: SsrvpnHomeTrafficPanel(
                            active: false,
                            connected: false,
                            readSample: () async => null,
                            accountUsage: AccountUsage.parse(json)))))));
        final cards = find.byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>)
                .value
                .startsWith('home-traffic-card-'));
        final rects = cards
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)))
            .toList();
        original ??= rects;
        expect(rects, original);
        expect(cards, findsNWidgets(5));
        for (final element in find
            .descendant(of: cards, matching: find.byType(RichText))
            .evaluate()) {
          expect((element.renderObject! as RenderParagraph).didExceedMaxLines,
              isFalse,
              reason: (element.renderObject! as RenderParagraph)
                  .text
                  .toPlainText());
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('same home survives continuous resize at scale $scale',
        (tester) async {
      final five = ValueNotifier(true);
      addTearDown(five.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var toggles = 0, navigation = 0, updates = 0;
      await tester.binding.setSurfaceSize(const Size(380, 520));
      await tester.pumpWidget(MaterialApp(
          theme:
              ThemeData(fontFamily: fontPath.isEmpty ? null : 'UsageEvidence'),
          home: Builder(
              builder: (context) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                      body: SsrvpnHomeShell(
                          notices: const [
                        SsrvpnHomeNotice(
                            icon: Icons.error_outline,
                            color: Colors.red,
                            title: '操作未完成',
                            message: '连接未完成：本地端口被其他应用占用，请稍后重试。')
                      ],
                          body: SsrvpnHomeOverview(
                              isConnected: true,
                              isConnecting: false,
                              selectedNode: usageNode(
                                  name: '私家车-连续窗口缩放-完整长节点名称-123456789'),
                              selectedLatency: 30,
                              selectedCountryCode: 'US',
                              onToggleConnection: () => toggles++,
                              onOpenNodes: () {},
                              onShowAbout: () {},
                              onShowTutorial: () {},
                              onShowLogs: () {},
                              onRefreshPublicIp: () {},
                              bottomContent: ValueListenableBuilder<bool>(
                                  valueListenable: five,
                                  builder: (context, visible, child) =>
                                      SsrvpnHomeTrafficPanel(
                                          active: false,
                                          connected: false,
                                          accountUsage: visible
                                              ? AccountUsage.parse(usageJson(
                                                  used: 9223372036854775807,
                                                  online: 9223372036854775807))
                                              : null,
                                          readSample: () async => null))),
                          navigation: SsrvpnBottomNavigation(
                              currentIndex: 0,
                              version: '4.0.29',
                              availableVersion: '4.0.30',
                              onUpdateTap: () => updates++,
                              onTap: (_) => navigation++)))))));
      final state = tester.state(find.byType(SsrvpnHomeTrafficPanel));
      for (final width in [
        for (var w = 380.0; w <= 1200; w += 20) w,
        for (var w = 1200.0; w >= 380; w -= 20) w,
      ]) {
        final size = Size(width, 520 + (width - 380) * .2);
        await tester.binding.setSurfaceSize(size);
        for (final visible in [true, false, true]) {
          five.value = visible;
          await tester.pump();
          expect(
              tester.state(find.byType(SsrvpnHomeTrafficPanel)), same(state));
          expect(find.byType(Scrollable), findsNothing);
          final cards = find.byWidgetPredicate((w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>)
                  .value
                  .startsWith('home-traffic-card-'));
          expect(cards, findsNWidgets(visible ? 5 : 3));
          final nav = tester.getRect(find.byType(SsrvpnBottomNavigation));
          final rects = cards
              .evaluate()
              .map((e) => tester.getRect(find.byWidget(e.widget)))
              .toList();
          for (var i = 0; i < rects.length; i++) {
            expect(rects[i].left, greaterThanOrEqualTo(0));
            expect(rects[i].right, lessThanOrEqualTo(size.width));
            expect(rects[i].top, greaterThanOrEqualTo(0));
            expect(rects[i].bottom, lessThanOrEqualTo(nav.top));
            for (var j = i + 1; j < rects.length; j++) {
              expect(rects[i].overlaps(rects[j]), isFalse);
            }
          }
          for (final text in find
              .descendant(of: cards, matching: find.byType(RichText))
              .evaluate()) {
            expect((text.renderObject! as RenderParagraph).didExceedMaxLines,
                isFalse);
          }
          expect(tester.takeException(), isNull,
              reason: '$size scale=$scale five=$visible');
        }
        await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
        await tester.tap(find.text('订阅').hitTestable().first);
        await tester.tap(find.byKey(const Key('ssrvpn-update-now-button')));
      }
      expect(toggles, 84);
      expect(navigation, 84);
      expect(updates, 84);
      await tester.pumpWidget(const SizedBox());
    });
  }
  tearDownAll(() async {
    if (screenshotDirectory.isNotEmpty) {
      final directory = Directory(screenshotDirectory);
      await directory.create(recursive: true);
      await File('${directory.path}/measurements.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
    }
  });
}
