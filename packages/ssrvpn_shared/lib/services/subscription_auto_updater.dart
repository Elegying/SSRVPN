import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/subscription.dart';
import '../models/subscription_update_schedule.dart';
import 'subscription_refresh_control.dart';
import 'subscription_refresh_result.dart';

/// One scheduler per subscription service, independent of the selected page.
/// No native wakeup: a suspended/closed app catches up once when it runs again.
class SubscriptionAutoUpdater extends ChangeNotifier {
  SubscriptionAutoUpdater(
      {required this.subscriptions,
      required this.isRemote,
      required this.refresh,
      required this.write,
      DateTime Function()? now,
      this.pollInterval = const Duration(seconds: 30)})
      : _now = now ?? DateTime.now;
  final List<Subscription> Function() subscriptions;
  final bool Function(Subscription) isRemote;
  final Future<SubscriptionBatchRefreshResult> Function(
      Set<String>, SubscriptionRefreshCancellation) refresh;
  final Future<void> Function(File, String) write;
  final DateTime Function() _now;
  final Duration pollInterval;
  SubscriptionUpdateSchedule? _schedule;
  SubscriptionUpdateSchedule? get schedule => _schedule;
  DateTime? lastAttempt;
  String? lastResult;
  bool get running => _running;
  bool _running = false, _disposed = false;
  File? _file;
  Timer? _timer;
  int _epoch = 0;
  Future<void> _tail = Future.value();
  SubscriptionRefreshCancellation? _cancellation;
  List<Subscription> get remoteSubscriptions =>
      subscriptions().where(isRemote).toList();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> load(String directory) async {
    _file = File('$directory/subscription_schedule.json');
    try {
      if (await _file!.exists()) {
        if (await _file!.length() > 1024 * 1024) throw const FormatException();
        final json = jsonDecode(await _file!.readAsString());
        if (json is! Map) throw const FormatException();
        _schedule = SubscriptionUpdateSchedule.fromJson(json['schedule']);
        final attempt = json['lastAttempt'];
        lastAttempt = attempt is String ? DateTime.tryParse(attempt) : null;
        if ((json['schedule'] != null && _schedule == null) ||
            (attempt != null && lastAttempt == null)) {
          throw const FormatException('自动更新记录无效');
        }
        lastResult =
            json['lastResult'] is String ? json['lastResult'] as String : null;
      }
    } catch (_) {
      lastResult = '自动更新设置读取失败，请重新保存计划';
      _schedule = null;
      lastAttempt = null;
    }
    _arm();
  }

  Future<void> _persist(SubscriptionUpdateSchedule? schedule, DateTime? attempt,
      String? result) async {
    if (_file == null) throw StateError('订阅存储尚未初始化');
    await write(
        _file!,
        jsonEncode({
          'schedule': schedule?.toJson(),
          'lastAttempt': attempt?.toUtc().toIso8601String(),
          'lastResult': result
        }));
  }

  Future<void> save(SubscriptionUpdateSchedule? value) => _serialize(() async {
        if (_disposed) return;
        final remoteIds = remoteSubscriptions.map((s) => s.id).toSet();
        final ids =
            value?.subscriptionIds.intersection(remoteIds) ?? <String>{};
        final candidate = value == null || ids.isEmpty
            ? null
            : SubscriptionUpdateSchedule(
                subscriptionIds: ids,
                hour: value.hour,
                minute: value.minute,
                weekdays: value.weekdays,
                createdAt: _now());
        await _persist(candidate, null, null);
        if (_disposed) return;
        _epoch++;
        _cancellation?.cancel();
        _schedule = candidate;
        lastAttempt = null;
        lastResult = null;
        _arm();
        notifyListeners();
      });

  void _arm() {
    _timer?.cancel();
    if (_disposed || _schedule?.enabled != true) return;
    _timer = Timer.periodic(pollInterval, (_) => unawaited(checkDue()));
    unawaited(checkDue());
  }

  Future<void> checkDue() async {
    if (_disposed || _running || _schedule?.enabled != true) return;
    _running = true;
    final epoch = _epoch;
    try {
      Set<String>? ids;
      await _serialize(() async {
        if (_disposed || epoch != _epoch) return;
        final plan = _schedule;
        final now = _now();
        if (plan == null || plan.dueAt(now, lastAttempt) == null) return;
        ids = remoteSubscriptions
            .where((s) => s.enabled && plan.subscriptionIds.contains(s.id))
            .map((s) => s.id)
            .toSet();
        // Persist admission before network I/O, preventing duplicate catch-up on restart.
        await _persist(plan, now, '上次自动更新未完成，可手动更新订阅');
        lastAttempt = now;
        lastResult = '正在自动更新订阅…';
      });
      if (ids == null || _disposed || epoch != _epoch) return;
      _cancellation = SubscriptionRefreshCancellation();
      notifyListeners();
      String result;
      try {
        if (ids!.isEmpty) {
          result = '本次没有启用且被勾选的订阅';
        } else {
          final outcome = await refresh(ids!, _cancellation!);
          result = outcome.failures.isEmpty
              ? '已更新 ${outcome.successfulSubscriptionIds.length} 个订阅'
              : '${outcome.successfulSubscriptionIds.length} 个成功，${outcome.failures.length} 个失败；失败来源保留原数据，可手动重试';
        }
      } on SubscriptionBatchRefreshException catch (error) {
        result = error.failures.isNotEmpty &&
                error.failures
                    .every((f) => f.diagnosticCode == 'SUB_PROXY_REQUIRED')
            ? '自动更新需要已连接的节点；请连接后在订阅页重试'
            : '自动更新失败，原数据已保留；请在订阅页重试并查看原因';
      } catch (_) {
        result = '自动更新失败，原数据已保留；请检查网络后手动更新订阅';
      }
      await _serialize(() async {
        if (_disposed || epoch != _epoch) return;
        await _persist(_schedule, lastAttempt, result);
        lastResult = result;
      });
    } catch (_) {
      if (!_disposed && epoch == _epoch) lastResult = '自动更新记录保存失败，请检查存储权限';
    } finally {
      _running = false;
      _cancellation = null;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _timer?.cancel();
    _cancellation?.cancel();
    super.dispose();
  }
}
