import 'dart:io';
import 'package:flutter/services.dart';
import 'package:ssrvpn_shared/controllers/account_usage_controller.dart';
import 'package:ssrvpn_shared/models/account_usage.dart';
import 'package:ssrvpn_shared/services/account_usage_client.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_home_statistics.dart';
import 'account_usage_test.dart' show usageProviders, usageNode, usageJson;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/network_verification.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_home_overview.dart';

void main() {
  const fontPath = String.fromEnvironment('SSRVPN_LAYOUT_FONT');
  setUpAll(() async {
    if (fontPath.isEmpty) return;
    final loader = FontLoader('ReliabilityEvidence');
    loader.addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
    await loader.load();
  });
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(660, 510)
  ]) {
    testWidgets('historical account numbers and timestamp fit ${size.width}',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var calls = 0;
      final start = tester.binding.clock.now();
      final controller = AccountUsageController(
          providers: usageProviders(),
          elapsed: () => tester.binding.clock.now().difference(start),
          wallNow: tester.binding.clock.now,
          fetch: (_) async {
            if (++calls > 1) {
              throw const UsageQueryFailure.reason(UsageFailureKind.timeout);
            }
            return AccountUsage.parse(usageJson(used: 12, online: 2));
          });
      addTearDown(controller.dispose);
      final selected = usageNode();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SsrvpnHomeOverview(
        isConnected: true,
        isConnecting: false,
        selectedNode: selected,
        selectedLatency: 30,
        selectedCountryCode: 'UN',
        hasAccountStatistics: true,
        networkVerification: const NetworkVerification(),
        bottomContent: SsrvpnHomeStatistics(
            active: true,
            connected: true,
            node: selected,
            revision: null,
            readSample: () async => null,
            controller: controller),
        onToggleConnection: () {},
        onOpenNodes: () {},
        onShowAbout: () {},
        onShowTutorial: () {},
        onShowLogs: () {},
        onRefreshPublicIp: () {},
      ))));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      expect(controller.isStale, isTrue);
      expect(find.textContaining('上次数据，暂未更新'), findsOneWidget);
      expect(find.text('已用流量'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final size in [
    const Size(390, 844),
    const Size(320, 568),
    const Size(660, 510)
  ]) {
    for (final state in NetworkVerificationState.values) {
      testWidgets(
          'home ${size.width} ${state.name} keeps verification details offscreen',
          (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var diagnostics = 0;
        final boundary = GlobalKey();
        final network = NetworkVerification(
            state: state,
            checkedAt: state == NetworkVerificationState.pending
                ? null
                : DateTime(2026, 10, 9, 12, 30),
            requestMilliseconds:
                state == NetworkVerificationState.pending ? null : 247);
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData.dark().copyWith(
                textTheme: ThemeData.dark().textTheme.apply(
                    fontFamily:
                        fontPath.isEmpty ? null : 'ReliabilityEvidence')),
            home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                    body: SsrvpnHomeOverview(
                  isConnected: true,
                  isConnecting: false,
                  selectedNode: ProxyNode(
                      name: '已选节点',
                      type: 'ss',
                      server: 'synthetic.test',
                      port: 443),
                  selectedLatency: 35,
                  selectedCountryCode: 'UN',
                  networkVerification: network,
                  connectionNotice: '系统代理所有权暂时无法确认',
                  onToggleConnection: () {},
                  onOpenNodes: () {},
                  onShowAbout: () {},
                  onShowTutorial: () {},
                  onShowLogs: () => diagnostics++,
                  onRefreshPublicIp: () {},
                )))));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text(network.label), findsOneWidget);
        if (state == NetworkVerificationState.verified) {
          expect(find.text('已连接'), findsOneWidget);
        }
        expect(find.textContaining('外网已验证可用'), findsNothing);
        expect(find.textContaining('最近验证'), findsNothing);
        expect(find.textContaining('2026-10-09'), findsNothing);
        expect(find.textContaining('247 ms'), findsNothing);
        expect(find.text('系统代理所有权暂时无法确认'), findsOneWidget);
        expect(find.textContaining('一键诊断'), findsNothing);
        expect(find.byKey(const Key('network-verification-details')),
            findsNothing);
        expect(diagnostics, 0);
        expect(tester.takeException(), isNull);
        final directory = Platform.environment['SSRVPN_RELIABILITY_OUTPUT'];
        if (directory != null && size.width == 390) {
          await tester.runAsync(() async {
            final image = await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(directory).create(recursive: true);
            await File('$directory/network-${state.name}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
