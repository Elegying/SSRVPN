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
  const output = String.fromEnvironment('SSRVPN_LAYOUT_OUTPUT');
  const fontPath = String.fromEnvironment('SSRVPN_LAYOUT_FONT');
  const iconPath = String.fromEnvironment('SSRVPN_LAYOUT_ICONS');
  final measurements = <Map<String, Object>>[];
  setUpAll(() async {
    for (final font
        in {'UsageEvidence': fontPath, 'MaterialIcons': iconPath}.entries) {
      if (font.value.isEmpty) continue;
      final loader = FontLoader(font.key);
      loader.addFont(File(font.value).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  for (final size in [
    const Size(380, 520), // Windows minimum minus titlebar.
    const Size(380, 532), // macOS minimum minus titlebar.
    const Size(380, 560),
    const Size(380, 720),
    const Size(380, 820),
    const Size(380, 900),
    const Size(390, 844),
    const Size(412, 892),
    const Size(800, 900)
  ]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
          'connected home anchors node at viewport center $size scale $scale',
          (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        Rect? originalNode;
        for (final five in [false, true, false]) {
          await tester.pumpWidget(MaterialApp(
            theme: ThemeData(
                fontFamily: fontPath.isEmpty ? null : 'UsageEvidence'),
            home: MediaQuery(
              data: MediaQueryData(
                  size: size, textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: RepaintBoundary(
                    key: const Key('spacing-capture'),
                    child: SsrvpnAppBackdrop(
                        child: SsrvpnHomeShell(
                      body: SsrvpnHomeOverview(
                          isConnected: true,
                          isConnecting: false,
                          selectedNode: usageNode(name: '私家车-隔离模拟账号'),
                          selectedLatency: 30,
                          selectedCountryCode: 'US',
                          publicIpv4: '192.0.2.1 US',
                          onToggleConnection: () {},
                          onOpenNodes: () {},
                          onShowAbout: () {},
                          onShowTutorial: () {},
                          onShowLogs: () {},
                          onRefreshPublicIp: () {},
                          bottomContent: SsrvpnHomeTrafficPanel(
                              active: false,
                              connected: true,
                              readSample: () async => null,
                              accountUsage: five
                                  ? AccountUsage.parse(
                                      usageJson(used: 9019431321, online: 2))
                                  : null)),
                      navigation: SsrvpnBottomNavigation(
                          currentIndex: 0, version: '布局验证', onTap: (_) {}),
                    ))),
              ),
            ),
          ));
          await tester.pumpAndSettle();
          Rect rect(String key) => tester.getRect(find.byKey(Key(key)));
          final status = rect('home-connection-status');
          final power = rect('ssrvpn-power-button');
          final node = rect('ssrvpn-current-node-card');
          final ip = rect('home-public-ip');
          expect(ip.top - node.bottom, greaterThanOrEqualTo(12));
          for (final text in find
              .descendant(
                  of: find.byKey(const Key('home-public-ip')),
                  matching: find.byType(RichText))
              .evaluate()) {
            final render = text.renderObject! as RenderParagraph;
            final bounds = render.localToGlobal(Offset.zero) & render.size;
            expect(ip.contains(bounds.topLeft), isTrue);
            expect(bounds.right, lessThanOrEqualTo(ip.right));
            expect(bounds.bottom, lessThanOrEqualTo(ip.bottom));
            expect(render.didExceedMaxLines, isFalse);
          }
          expect(
              ip.bottom, lessThanOrEqualTo(rect('home-traffic-card-上传速率').top));
          final firstCard = rect('home-traffic-card-上传速率');
          expect(rect('home-traffic-panel').bottom,
              closeTo(rect('ssrvpn-home-content').bottom, .1),
              reason:
                  'Statistics must remain anchored above the bottom navigation');
          final spareGaps = <double>[];
          if (find
              .byKey(const Key('home-overview-header'))
              .evaluate()
              .isNotEmpty) {
            final header = rect('home-overview-header');
            final centered = rect('ssrvpn-home-content').height >= 602;
            if (centered) {
              expect(node.center.dy, closeTo(size.height / 2, .1));
              expect(node.center.dx, closeTo(size.width / 2, .1));
            }
            spareGaps.addAll([
              status.top - header.bottom - 12,
              power.top - status.bottom - 10,
              node.top - power.bottom - 12,
              firstCard.top - ip.bottom - 12,
            ]);
            // Share upper spare height without moving the centered card.
            for (final gap in spareGaps.take(3)) {
              expect(gap, greaterThanOrEqualTo(-.1));
              expect(gap, closeTo(spareGaps.first, .1));
            }
          }
          expect(power.width, closeTo(power.height, .1));
          expect(power.center.dx, closeTo(status.center.dx, .1));
          expect(find.byType(Scrollable), findsNothing);
          expect(tester.takeException(), isNull);
          if (!five) {
            originalNode ??= node;
            expect(node, originalNode,
                reason: '3-5-3 must restore spacing without residual gaps');
          }
          measurements.add({
            'viewport': '${size.width.toInt()}x${size.height.toInt()}',
            'scale': scale,
            'cards': five ? 5 : 3,
            'nodeToIp': ip.top - node.bottom,
            if (spareGaps.isNotEmpty) ...{
              'headerToStatus': spareGaps[0] + 12,
              'statusToPower': spareGaps[1] + 10,
              'powerToNode': spareGaps[2] + 12,
              'detailsToStatistics': spareGaps[3] + 12,
            },
          });
          if (output.isNotEmpty && scale == 1) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(const Key('spacing-capture')));
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 2);
              final bytes =
                  await image.toByteData(format: ui.ImageByteFormat.png);
              image.dispose();
              await Directory(output).create(recursive: true);
              await File(
                      '$output/balanced-${size.width.toInt()}x${size.height.toInt()}-${five ? 5 : 3}.png')
                  .writeAsBytes(bytes!.buffer.asUint8List());
            });
          }
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  tearDownAll(() async {
    if (output.isEmpty) return;
    await Directory(output).create(recursive: true);
    await File('$output/spacing-measurements.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(measurements));
  });
}
