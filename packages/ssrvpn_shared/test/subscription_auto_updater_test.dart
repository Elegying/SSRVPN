import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/models/subscription_update_schedule.dart';
import 'package:ssrvpn_shared/services/subscription_auto_updater.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_result.dart';

void main() {
  test('daily and weekday schedules use local calendar, catch up only once',
      () {
    final daily = SubscriptionUpdateSchedule(
        subscriptionIds: {'a'},
        hour: 9,
        minute: 30,
        createdAt: DateTime(2026, 10, 5, 10));
    expect(daily.dueAt(DateTime(2026, 10, 6, 9, 29), null), isNull);
    expect(daily.dueAt(DateTime(2026, 10, 6, 9, 30), null),
        DateTime(2026, 10, 6, 9, 30));
    expect(
        daily.dueAt(DateTime(2026, 10, 10), DateTime(2026, 10, 9, 10)), isNull);
    final weekly = SubscriptionUpdateSchedule(
        subscriptionIds: {'a'},
        hour: 18,
        minute: 5,
        weekdays: {1, 5},
        createdAt: DateTime(2026, 10, 5, 19));
    expect(weekly.dueAt(DateTime(2026, 10, 9, 18, 5), null),
        DateTime(2026, 10, 9, 18, 5));
    expect(
        weekly.dueAt(
            DateTime(2026, 10, 9, 18, 5), DateTime(2026, 10, 9, 18, 5)),
        isNull);
    expect(
        SubscriptionUpdateSchedule.fromJson(weekly.toJson())!.weekdays, {1, 5});
    expect(
        SubscriptionUpdateSchedule.fromJson({
          'ids': ['a'],
          'weekdays': [8],
          'hour': 9,
          'minute': 0,
          'createdAt': '2026-10-06'
        }),
        isNull);
  });
  late Directory dir;
  late DateTime now;
  late SubscriptionAutoUpdater updater;
  late List<Subscription> subs;
  late List<Set<String>> calls;
  Completer<SubscriptionBatchRefreshResult>? pending;
  SubscriptionRefreshCancellation? cancellation;
  var failWrite = false;
  const success = SubscriptionBatchRefreshResult(
      status: SubscriptionBatchRefreshStatus.success,
      yaml: '',
      successfulSubscriptionIds: ['a']);
  SubscriptionAutoUpdater make() => SubscriptionAutoUpdater(
      subscriptions: () => subs,
      isRemote: (s) => s.url.startsWith('https://'),
      now: () => now,
      pollInterval: const Duration(days: 1),
      write: (file, text) async {
        if (failWrite) throw const FileSystemException('fixture');
        await file.writeAsString(text);
      },
      refresh: (ids, token) {
        calls.add(ids);
        cancellation = token;
        return pending?.future ?? Future.value(success);
      });
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('subscription-schedule-');
    now = DateTime(2026, 10, 6, 8);
    calls = [];
    subs = [
      Subscription(id: 'a', name: 'A', url: 'https://a.invalid'),
      Subscription(
          id: 'b', name: 'B', url: 'https://b.invalid', enabled: false),
      Subscription(
          id: 'local', name: 'Local', url: 'trojan://fixture@node.invalid:443')
    ];
    pending = null;
    cancellation = null;
    failWrite = false;
    updater = make();
    await updater.load(dir.path);
  });
  tearDown(() async {
    updater.dispose();
    await Future<void>.delayed(Duration.zero);
    await dir.delete(recursive: true);
  });
  Future<void> save() async {
    await updater.save(SubscriptionUpdateSchedule(
        subscriptionIds: {'a', 'b', 'local', 'deleted'},
        hour: 9,
        minute: 0,
        createdAt: now));
    // Let the immediate admission check finish before moving the clock.
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  test(
      'opt in, excludes local/deleted/disabled and survives restart without duplicate',
      () async {
    expect(updater.schedule, isNull);
    await save();
    expect(updater.schedule!.subscriptionIds, {'a', 'b'});
    now = DateTime(2026, 10, 7, 10);
    await updater.checkDue();
    await updater.checkDue();
    expect(calls, [
      {'a'}
    ]);
    updater.dispose();
    updater = make();
    await updater.load(dir.path);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, hasLength(1));
    now = DateTime(2026, 10, 8, 10);
    await updater.checkDue();
    expect(calls, hasLength(2));
  });
  test('write failure retains saved plan and stops requests before admission',
      () async {
    await save();
    failWrite = true;
    await expectLater(updater.save(null), throwsA(isA<FileSystemException>()));
    expect(updater.schedule, isNotNull);
    now = DateTime(2026, 10, 7, 10);
    await updater.checkDue();
    expect(calls, isEmpty);
    failWrite = false;
    await updater.checkDue();
    expect(calls, hasLength(1));
  });
  test(
      'disabling during refresh cancels old request and prevents stale status overwrite',
      () async {
    await save();
    pending = Completer();
    now = DateTime(2026, 10, 7, 10);
    final task = updater.checkDue();
    while (cancellation == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await updater.checkDue();
    expect(calls, hasLength(1));
    await updater.save(null);
    expect(cancellation!.isCancelled, isTrue);
    pending!.complete(success);
    await task;
    expect(updater.schedule, isNull);
    expect(updater.lastResult, isNull);
  });
  test('weekly catch-up crosses month and year without replaying older slots',
      () {
    final plan = SubscriptionUpdateSchedule(
        subscriptionIds: {'a'},
        weekdays: {1},
        hour: 0,
        minute: 0,
        createdAt: DateTime(2025, 12, 28));
    expect(plan.dueAt(DateTime(2026, 1, 1), null), DateTime(2025, 12, 29));
    expect(plan.dueAt(DateTime(2026, 1, 1), DateTime(2025, 12, 30)), isNull);
    expect(plan.dueAt(DateTime(2026, 2, 1), DateTime(2025, 12, 30)),
        DateTime(2026, 1, 26));
    expect(plan.dueAt(DateTime(2026, 1, 1), DateTime(2026, 2, 1)), isNull);
  });

  test('deleted scheduled sources never become a refresh-all request',
      () async {
    await save();
    subs.removeWhere((s) => s.id == 'a');
    now = DateTime(2026, 10, 7, 10);
    await updater.checkDue();
    expect(calls, isEmpty);
    expect(updater.lastResult, '本次没有启用且被勾选的订阅');
  });

  test('result write failure after refresh does not replay on restart',
      () async {
    await save();
    pending = Completer();
    now = DateTime(2026, 10, 7, 10);
    final task = updater.checkDue();
    while (cancellation == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    failWrite = true;
    pending!.complete(success);
    await task;
    expect(updater.lastResult, contains('保存失败'));
    updater.dispose();
    failWrite = false;
    pending = null;
    updater = make();
    await updater.load(dir.path);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, hasLength(1));
    expect(updater.lastResult, contains('未完成'));
  });

  test('dispose cancels admitted work and prevents a late status publication',
      () async {
    await save();
    pending = Completer();
    now = DateTime(2026, 10, 7, 10);
    final task = updater.checkDue();
    while (cancellation == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    var publications = 0;
    updater.addListener(() => publications++);
    updater.dispose();
    expect(cancellation!.isCancelled, isTrue);
    pending!.complete(success);
    await task;
    expect(publications, 0);
    updater = make();
    await updater.load(dir.path);
  });
  for (final brokenField in ['schedule', 'lastAttempt']) {
    test('invalid persisted $brokenField is visible and never replays requests',
        () async {
      await save();
      updater.dispose();
      final file = File('${dir.path}/subscription_schedule.json');
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (brokenField == 'schedule') {
        (data['schedule'] as Map<String, dynamic>)['hour'] = 25;
      } else {
        data['lastAttempt'] = 'invalid-date';
      }
      data['lastResult'] = '已更新 1 个订阅';
      final original = jsonEncode(data);
      await file.writeAsString(original);
      now = DateTime(2026, 10, 7, 10);
      updater = make();
      await updater.load(dir.path);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(updater.schedule, isNull);
      expect(updater.lastResult, contains('读取失败'));
      expect(calls, isEmpty);
      expect(await file.readAsString(), original);
      await save();
      now = DateTime(2026, 10, 8, 10);
      await updater.checkDue();
      expect(calls, [
        {'a'}
      ]);
      expect(updater.lastResult, '已更新 1 个订阅');
    });
  }
}
