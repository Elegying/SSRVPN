import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/subscription_service_base.dart';

typedef LatencyTestLaunch = ({
  Widget widget,
  SubscriptionServiceBase subscription,
});

Future<void> flushLatencyHistory(
    WidgetTester tester, SubscriptionServiceBase subscription) async {
  var persisted = false;
  final persistence = subscription.flushLatencyResults().then((_) {
    persisted = true;
  });
  // Writes begin from UI callbacks in FakeAsync. Pump their continuations while
  // allowing real I/O to finish before a fixture deletes its temporary directory.
  await tester.runAsync(() async {
    for (var i = 0; i < 200 && !persisted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  expect(persisted, isTrue, reason: 'Latency history must reach disk.');
  await persistence;
}

/// Exercise the real platform HomeScreen and a fresh disk-backed service.
Future<void> verifyLatencyHistoryAcrossLaunches(
  WidgetTester tester, {
  required LatencyTestLaunch first,
  required Future<LatencyTestLaunch> Function() restart,
  required int Function() probeCount,
  required String replacementYaml,
}) async {
  await tester.pumpWidget(first.widget);
  await tester.pumpAndSettle();
  expect(probeCount(), 0);
  await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
  await tester.pumpAndSettle();
  expect(find.text('--'), findsNWidgets(2));
  await tester.tap(find.byTooltip('测试当前分组延迟'));
  await tester.pumpAndSettle();
  expect(find.text('42ms'), findsOneWidget);
  expect(find.text('68ms'), findsOneWidget);
  expect(probeCount(), greaterThan(0));
  final testsBeforeRestart = probeCount();
  final originals = first.subscription.allNodes;
  final timestamps =
      originals.map((node) => node.lastLatencyTest?.toUtc()).toList();
  expect(timestamps, everyElement(isNotNull));
  await flushLatencyHistory(tester, first.subscription);
  await tester.pumpWidget(const SizedBox.shrink());
  final next = (await tester.runAsync(restart))!;
  expect(identical(next.subscription, first.subscription), isFalse);
  expect(identical(next.subscription.allNodes.first, originals.first), isFalse);
  expect(
      next.subscription.allNodes.map((node) => node.lastLatencyTest?.toUtc()),
      timestamps);
  await tester.pumpWidget(next.widget);
  await tester.pumpAndSettle();
  expect(find.text('42ms'), findsOneWidget);
  await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
  await tester.pumpAndSettle();
  expect(find.text('42ms'), findsOneWidget);
  expect(find.text('68ms'), findsOneWidget);
  expect(probeCount(), testsBeforeRestart,
      reason: 'Displaying history must not start another probe.');

  await tester.runAsync(() => next.subscription.setRawYaml(replacementYaml));
  await tester.pumpAndSettle();
  expect(find.text('42ms'), findsNothing);
  expect(find.text('--'), findsOneWidget);
  expect(find.text('68ms'), findsOneWidget);
  expect(probeCount(), testsBeforeRestart);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
}
