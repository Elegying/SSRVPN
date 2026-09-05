import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Future<VpnTrafficSample?> Function() reader;

  VpnTrafficSample sample(int time, int upload, int download,
          {int session = 1}) =>
      VpnTrafficSample(
          sessionGeneration: session,
          sampledAtMillis: time,
          upload: upload,
          download: download);

  VpnTrafficSample data(int time, int upload, int download,
          {int session = 1}) =>
      sample(time, upload, download, session: session);

  Widget host({bool active = true, bool connected = true, double scale = 1}) =>
      MaterialApp(
          home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
            bottomNavigationBar: SsrvpnHomeTrafficPanel(
          active: active,
          connected: connected,
          readSample: () => reader(),
        )),
      ));

  test('rates use elapsed time and never mix sessions or regressing counters',
      () {
    final first = sample(1000, 1024, 2048);
    final next = sample(3000, 5120, 10240);
    expect(next.ratesSince(first), (upload: 2048.0, download: 4096.0));
    expect(next.total, 15360);
    expect(next.ratesSince(null), (upload: 0.0, download: 0.0));
    expect(next.ratesSince(next), (upload: 0.0, download: 0.0));
    expect(first.ratesSince(next), (upload: 0.0, download: 0.0));
    expect(sample(4000, 0, 0, session: 2).ratesSince(next),
        (upload: 0.0, download: 0.0));
    expect(sample(4000, 1, 1).ratesSince(next), (upload: 0.0, download: 0.0));
    expect(formatVpnTraffic(0, rate: true), '0 B/s');
    expect(formatVpnTraffic(1024, rate: true), '1.0 KB/s');
    expect(formatVpnTraffic(2.4 * 1024 * 1024 * 1024), '2.4 GB');
    expect(formatVpnTraffic(1024 * 1024 * 1024 * 1024 * 1024), '1.0 PB');
    expect(formatVpnTraffic(9223372036854775807), '8.0 EB');
    expect(
        formatVpnTraffic(9223372036854775807 / 0.001, rate: true), '7.8 ZB/s');
  });

  for (final width in [320.0, 400.0, 800.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('traffic cards never resize at width $width scale $scale',
          (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var current = data(0, 0, 0);
        var unavailable = false;
        reader = () async {
          if (unavailable) throw const FormatException('Unavailable');
          return current;
        };
        await tester.pumpWidget(MaterialApp(
            home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
              body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: SsrvpnHomeTrafficPanel(
                active: true, connected: true, readSample: () => reader()),
          )),
        )));
        await tester.pump();
        const labels = ['上传速率', '下载速率', '本次累计'];
        final initial = {
          for (final label in labels)
            label: tester
                .getRect(find.byKey(ValueKey('home-traffic-card-$label'))),
        };
        expect(initial.values.map((r) => r.height).toSet(), hasLength(1));
        for (final bytes in [
          1,
          999,
          1023,
          1024,
          1048575,
          1073741824,
          1125899906842624,
          4611686018427387903
        ]) {
          current = data(current.sampledAtMillis + 1, bytes, bytes);
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          for (final label in labels) {
            expect(
                tester
                    .getRect(find.byKey(ValueKey('home-traffic-card-$label'))),
                initial[label]);
            for (final field in ['number', 'unit']) {
              final box = tester.renderObject<RenderBox>(
                  find.byKey(ValueKey('home-traffic-$field-$label')));
              final topLeft = box.localToGlobal(Offset.zero);
              final bottomRight =
                  box.localToGlobal(box.size.bottomRight(Offset.zero));
              expect(topLeft.dx, greaterThanOrEqualTo(initial[label]!.left));
              expect(bottomRight.dx,
                  lessThanOrEqualTo(initial[label]!.right + 0.01));
              expect(topLeft.dy, greaterThanOrEqualTo(initial[label]!.top));
              expect(bottomRight.dy,
                  lessThanOrEqualTo(initial[label]!.bottom + 0.01));
            }
          }
          expect(tester.takeException(), isNull);
        }
        unavailable = true;
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        for (final label in labels) {
          expect(
              tester.getRect(find.byKey(ValueKey('home-traffic-card-$label'))),
              initial[label]);
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets(
      'polls while visible, includes background totals, clears on disconnect',
      (tester) async {
    var calls = 0;
    var current = data(1000, 1024, 2048);
    reader = () async {
      calls++;
      return current;
    };
    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.text('3.0'), findsOneWidget);
    current = data(2000, 2048, 4096);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('↑ 1.0'), findsOneWidget);
    expect(find.text('↓ 2.0'), findsOneWidget);

    await tester.pumpWidget(host(active: false));
    final beforeHidden = calls;
    await tester.pump(const Duration(seconds: 5));
    expect(calls, beforeHidden);
    current = data(10000, 10240, 20480);
    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.text('30.0'), findsOneWidget);
    expect(find.text('↑ 0'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final beforeBackground = calls;
    await tester.pump(const Duration(seconds: 5));
    expect(calls, beforeBackground);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(calls, beforeBackground + 1);

    await tester.pumpWidget(host(connected: false));
    await tester.pump();
    expect(find.text('0'), findsOneWidget);
    final beforeDisconnect = calls;
    await tester.pump(const Duration(seconds: 5));
    expect(calls, beforeDisconnect);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'ignores a delayed response after disconnect and recovers from errors',
      (tester) async {
    final pending = Completer<VpnTrafficSample>();
    reader = () => pending.future;
    await tester.pumpWidget(host());
    await tester.pumpWidget(host(connected: false));
    pending.complete(data(1000, 1024, 2048));
    await tester.pump();
    expect(find.text('0'), findsOneWidget);

    reader = () async => throw const FormatException('Invalid counter');
    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.text('—'), findsOneWidget);
    expect(find.text('↑ —'), findsOneWidget);
    reader = () async => data(2000, 1024, 2048);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('3.0'), findsOneWidget);
    expect(find.text('↑ 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [
    const Size(393, 852),
    const Size(320, 640),
    const Size(640, 320)
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('full home fits $size at text scale $scale', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        reader = () async => data(1000, 1288490188, 1288490188);
        await tester.pumpWidget(MaterialApp(
            home: MediaQuery(
          data:
              MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
          child: Scaffold(
              body: SsrvpnAppBackdrop(
                  child: Column(children: [
            Expanded(
                child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SsrvpnHomeOverview(
                bottomContent: SsrvpnHomeTrafficPanel(
                    active: true, connected: true, readSample: () => reader()),
                isConnected: true,
                isConnecting: false,
                selectedNode: null,
                selectedLatency: 30,
                selectedCountryCode: 'US',
                publicIpv4: '203.0.113.1 US',
                onToggleConnection: () {},
                onOpenNodes: () {},
                onShowAbout: () {},
                onShowTutorial: () {},
                onShowLogs: () {},
                onRefreshPublicIp: () {},
              ),
            )),
            SsrvpnBottomNavigation(
                currentIndex: 0, version: '4.0.28', onTap: (_) {}),
          ]))),
        )));
        await tester.pump();
        expect(find.text('上传速率'), findsOneWidget);
        expect(find.text('下载速率'), findsOneWidget);
        expect(find.text('本次累计'), findsOneWidget);
        expect(find.text('2.4'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('home-traffic-panel')));
        await tester.pump();
        final panel =
            tester.getRect(find.byKey(const Key('home-traffic-panel')));
        final nav = tester.getRect(find.byType(SsrvpnBottomNavigation));
        expect(panel.bottom, lessThanOrEqualTo(nav.top));
        expect(panel.left, greaterThanOrEqualTo(0));
        expect(panel.right, lessThanOrEqualTo(size.width));
        expect(panel.height, lessThan(180));
        if (size.height > size.width && scale == 1) {
          expect(find.byKey(const Key('ssrvpn-power-button')).hitTestable(),
              findsOneWidget);
          expect(
              find.byKey(const Key('ssrvpn-current-node-card')).hitTestable(),
              findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
