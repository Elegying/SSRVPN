import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/subscription_usage.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_expiry_notice.dart';

void main() {
  testWidgets(
      'expiry is advisory, updates at its deadline, and clears on renewal',
      (tester) async {
    final now = tester.binding.clock.now;
    final base = now();
    SubscriptionUsage usage(int seconds) => SubscriptionUsage(
        expire:
            base.add(Duration(seconds: seconds)).millisecondsSinceEpoch ~/ 1000,
        updatedAt: base);
    Widget host(SubscriptionUsage? usage, {bool active = true}) => MaterialApp(
        home: SsrvpnSubscriptionExpiryNotice(
            usage: usage, active: active, now: now));
    await tester.pumpWidget(host(usage(5)));
    expect(find.textContaining('ACCOUNT_EXPIRED'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(find.textContaining('账号已到期'), findsOneWidget);
    expect(find.textContaining('请更新订阅'), findsOneWidget);
    expect(tester.widget<Tooltip>(find.byType(Tooltip)).message,
        contains('订阅信息更新于'));
    await tester.pumpWidget(host(usage(60)));
    expect(find.textContaining('ACCOUNT_EXPIRED'), findsNothing);
    await tester.pumpWidget(host(null));
    await tester.pump(const Duration(seconds: 60));
    expect(find.textContaining('ACCOUNT_EXPIRED'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'switching sources cancels old deadlines and unknown expiry stays unknown',
      (tester) async {
    final now = tester.binding.clock.now;
    final base = now();
    Widget host(SubscriptionUsage usage, {bool active = true}) => MaterialApp(
        home: SsrvpnSubscriptionExpiryNotice(
            usage: usage, active: active, now: now));
    SubscriptionUsage usage(int? seconds) => SubscriptionUsage(
        expire: seconds == null
            ? null
            : base.millisecondsSinceEpoch ~/ 1000 + seconds,
        updatedAt: base);
    await tester.pumpWidget(host(usage(1)));
    await tester.pumpWidget(host(usage(120)));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('ACCOUNT_EXPIRED'), findsNothing);
    await tester.pumpWidget(host(usage(null)));
    await tester.pump(const Duration(seconds: 130));
    expect(find.textContaining('ACCOUNT_EXPIRED'), findsNothing);
    await tester
        .pumpWidget(host(SubscriptionUsage(expire: 0, updatedAt: base)));
    expect(find.textContaining('ACCOUNT_EXPIRED'), findsNothing);
    await tester.pumpWidget(host(SubscriptionUsage(
        expire: 1, updatedAt: now().add(const Duration(days: 1)))));
    expect(find.textContaining('ACCOUNT_EXPIRED'), findsNothing);
    await tester.pumpWidget(host(usage(150), active: false));
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpWidget(host(usage(150)));
    expect(find.textContaining('ACCOUNT_EXPIRED'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('home shows expiry only for eligible source metadata',
      (tester) async {
    final usage = SubscriptionUsage(expire: 1, updatedAt: DateTime(2020));
    Widget host(ProxyNode node) => MaterialApp(
        home: Center(
            child: SizedBox(
                width: 380,
                height: 200,
                child: SsrvpnHomeStatistics(
                    active: true,
                    connected: false,
                    node: node,
                    revision: null,
                    subscriptionUsage: usage,
                    readSample: () async => null))));
    final node = ProxyNode(
        name: '普通', type: 'hysteria2', server: 'a.example.test', port: 443);
    await tester.pumpWidget(host(node));
    expect(find.textContaining('ACCOUNT_EXPIRED'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(host(node.copyWith(name: '私家车')));
    expect(find.textContaining('ACCOUNT_EXPIRED'), findsNothing);
    await tester
        .pumpWidget(host(node.copyWith(name: '改名', server: 'a.ssrvpn.vip')));
    expect(find.textContaining('ACCOUNT_EXPIRED'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
