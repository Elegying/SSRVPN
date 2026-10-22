// Run explicitly with flutter test; timings are observations, never CI limits.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/services/node_pin_store.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_node_selection_page.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_theme.dart';

void main() {
  for (final count in [960, 4800]) {
    for (final sorted in [false, true]) {
      testWidgets('$count nodes, latency sorting $sorted', (tester) async {
        final nodes = List.generate(
          count,
          (i) => ProxyNode(
            name: 'Node $i',
            type: 'ss',
            server: '192.0.2.${i % 250 + 1}',
            port: 443,
            group: 'Source ${i % 4}',
            latency: 10 + i % 180,
          ),
        );
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('ssrvpn-node-benchmark-'),
        ))!;
        final pins = NodePinStore(directory.path);
        await tester.runAsync(() async {
          await pins.load();
          await pins.toggle(nodes.last);
          await pins.setSortByLatency(sorted);
        });
        final refresh = ValueNotifier<int>(0);
        await tester.pumpWidget(MaterialApp(
          theme: SsrvpnTheme(AppThemeVariant.cloud).material(
            ThemeData.dark().copyWith(platform: TargetPlatform.macOS),
          ),
          home: SsrvpnNodeSelectionPage(
            preferenceDirectory: directory.path,
            pinStoreFactory: (_) => pins,
            ownerStateListenable: refresh,
            nodesOf: () => nodes,
            selectedNodeNameOf: () => nodes.first.name,
            proxyModeOf: () => ProxyMode.rule,
            testingNodeNameOf: () => null,
            isBatchTestingOf: () => false,
            isConnectingOf: () => false,
            countryCodeOf: (_) => 'UN',
            latencyOf: (node) => node.latency,
            onClose: () {},
            onRefresh: () async {},
            onTestAll: () async {},
            onTestLatency: (_) async {},
            onSelectNode: (_) async {},
            onProxyModeChanged: (_) async {},
          ),
        ));
        await tester.pumpAndSettle();
        expect(find.text(nodes.last.name), findsOneWidget);
        final results = <String, Object>{};
        for (final changingLatency in [false, true]) {
          final samples = <int>[];
          for (var iteration = 0; iteration < 35; iteration++) {
            if (changingLatency) {
              final node = nodes[iteration % nodes.length];
              node.latency = (node.latency! + 7) % 200 + 1;
            }
            final watch = Stopwatch()..start();
            refresh.value++;
            await tester.pump();
            watch.stop();
            if (iteration >= 10) samples.add(watch.elapsedMicroseconds);
          }
          samples.sort();
          results[changingLatency ? 'latency_update' : 'unchanged_refresh'] = {
            'samples_us': samples,
            'median_us': samples[samples.length ~/ 2],
            'p95_us': samples[(samples.length * .95).ceil() - 1],
          };
        }
        // This measures the real widget with Flutter's test renderer, not GPU
        // frame timings or an installed application's release performance.
        // ignore: avoid_print
        print('SSRVPN_NODE_BENCHMARK ${jsonEncode({
              'nodes': count,
              'sort_by_latency': sorted,
              'renderer': 'flutter-test',
              'results': results,
            })}');
        await tester.pumpWidget(const SizedBox.shrink());
        refresh.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      });
    }
  }
}
