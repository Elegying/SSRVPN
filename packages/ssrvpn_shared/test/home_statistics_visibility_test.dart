import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'account_usage_test.dart' show usageJson, usageNode, usageProviders;

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    testWidgets(
        '$platform visible statistics keep polling across focus changes',
        (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final origin = tester.binding.clock.now();
      Duration elapsed() => tester.binding.clock.now().difference(origin);
      var reads = 0;
      var queries = 0;
      final account = AccountUsageController(
          providers: usageProviders(),
          elapsed: elapsed,
          fetch: (_) async => AccountUsage.parse(usageJson(
              time: 1000 + ++queries, used: queries * 10, online: queries)));
      addTearDown(account.dispose);
      final revision = Object();
      Widget host({bool active = true}) => MaterialApp(
          home: Scaffold(
              body: SsrvpnHomeStatistics(
                  active: active,
                  connected: true,
                  node: usageNode(),
                  revision: revision,
                  controller: account,
                  readSample: () async {
                    reads++;
                    return VpnTrafficSample(
                        sessionGeneration: 1,
                        sampledAtMillis: elapsed().inMilliseconds + 1000,
                        upload: elapsed().inMilliseconds * 1024 ~/ 1000,
                        download: elapsed().inMilliseconds * 2048 ~/ 1000);
                  })));
      await tester.pumpWidget(host());
      await tester.pump(const Duration(milliseconds: 1));
      expect(reads, 1);
      expect(queries, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('↑1.0'), findsOneWidget);
      expect(find.text('↓2.0'), findsOneWidget);

      final beforeBlur = reads;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(reads, beforeBlur, reason: 'blur must not restart the sampler');
      expect(find.text('↑1.0'), findsOneWidget);
      for (var second = 0; second < 10; second++) {
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
      }
      expect(reads, beforeBlur + 10);
      expect(queries, 2);
      expect(account.value?.usedBytes, 20);
      expect(account.value?.onlineDevices, 2);
      final beforeFocus = reads;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(reads, beforeFocus,
          reason: 'focus must preserve the sample baseline');
      expect(find.text('↑1.0'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      final hiddenReads = reads;
      final hiddenQueries = queries;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(reads, hiddenReads);
      expect(queries, hiddenQueries);

      // A restored window can be visible before it receives keyboard focus.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(reads, hiddenReads + 1);
      expect(queries, hiddenQueries + 1);
      expect(find.text('↑0'), findsOneWidget);
      expect(find.text('123'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('↑1.0'), findsOneWidget);

      // An offscreen home page must still release both polling timers.
      await tester.pumpWidget(host(active: false));
      final offscreenReads = reads;
      final offscreenQueries = queries;
      await tester.pump(const Duration(seconds: 30));
      expect(reads, offscreenReads);
      expect(queries, offscreenQueries);
      await tester.pumpWidget(const SizedBox());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }, variant: TargetPlatformVariant({platform}));

    testWidgets(
        '$platform blur keeps pending data and hidden replies stay stale',
        (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final firstSample = Completer<VpnTrafficSample>();
      final hiddenSample = Completer<VpnTrafficSample>();
      final firstAccount = Completer<AccountUsage>();
      final account = AccountUsageController(
          providers: usageProviders(), fetch: (_) => firstAccount.future);
      addTearDown(account.dispose);
      var reads = 0;
      VpnTrafficSample sample(int time, int upload) => VpnTrafficSample(
          sessionGeneration: 1,
          sampledAtMillis: time,
          upload: upload,
          download: 0);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SsrvpnHomeStatistics(
                  active: true,
                  connected: true,
                  node: usageNode(),
                  revision: Object(),
                  controller: account,
                  readSample: () {
                    reads++;
                    return switch (reads) {
                      1 => firstSample.future,
                      2 => hiddenSample.future,
                      _ => Future.value(sample(3000, 8192)),
                    };
                  }))));
      await tester.pump(const Duration(milliseconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      firstSample.complete(sample(1000, 1024));
      firstAccount.complete(AccountUsage.parse(usageJson(used: 17)));
      await tester.pump();
      await tester.pump();
      expect(reads, 1);
      expect(find.text('1.0'), findsOneWidget);
      expect(account.value?.usedBytes, 17);

      await tester.pump(const Duration(seconds: 1));
      expect(reads, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump(const Duration(milliseconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump();
      expect(reads, 3);
      expect(find.text('8.0'), findsOneWidget);
      hiddenSample.complete(sample(2000, 4096));
      await tester.pump();
      expect(find.text('8.0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }, variant: TargetPlatformVariant({platform}));
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform retains its inactive sampling policy',
        (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var reads = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SsrvpnHomeTrafficPanel(
                  active: true,
                  connected: true,
                  readSample: () async {
                    reads++;
                    return null;
                  }))));
      await tester.pump(const Duration(milliseconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      final before = reads;
      await tester.pump(const Duration(seconds: 5));
      expect(reads, before);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(reads, before + 1);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant({platform}));
  }
}
