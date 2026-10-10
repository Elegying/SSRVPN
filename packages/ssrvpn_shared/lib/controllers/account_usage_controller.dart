import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/account_usage.dart';
import '../models/proxy_node.dart';
import '../services/account_usage_client.dart';
import '../services/account_usage_provider.dart';

/// Only one request in flight; current data is always a complete pair.
class AccountUsageController extends ChangeNotifier {
  AccountUsageController(
      {AccountUsageProviders? providers,
      Future<AccountUsage> Function(UsageIdentity)? fetch,
      Duration Function()? elapsed,
      DateTime Function()? wallNow,
      this.onDiagnostic})
      : _providers = providers ?? AccountUsageProviders.configured,
        _fetch = fetch ?? const AccountUsageClient().fetch {
    final clock = Stopwatch()..start();
    _now = elapsed ?? (() => clock.elapsed);
    _wallNow = wallNow ?? DateTime.now;
  }
  final void Function(String)? onDiagnostic;
  UsageQueryFailure? _failure;
  final AccountUsageProviders _providers;
  final Future<AccountUsage> Function(UsageIdentity) _fetch;
  late final Duration Function() _now;
  late final DateTime Function() _wallNow;
  ({Duration elapsed, DateTime wall})? _suspended;
  UsageIdentity? _identity;
  Object? _revision;
  AccountUsage? _value;
  Duration _expires = Duration.zero;
  Timer? _poll, _expiry;
  bool _active = false, _busy = false, _disposed = false;
  int _epoch = 0, _failures = 0;
  int? _lastServerTime;
  Duration _retryAt = Duration.zero;

  final Map<String, ({AccountUsage value, DateTime at})> _history = {};
  final Map<String, ({Duration until, int failures})> _retryBudgets = {};
  final Map<String, Duration> _serverRetryUntil = {};
  AccountUsage? get displayValue => value ?? _history[_identity?.key]?.value;
  bool get isStale =>
      displayValue != null && (value == null || _failure != null);

  AccountUsage? get value => _now() < _expires ? _value : null;

  String? get statusMessage {
    if (_identity == null) return null;
    final previous = _history[_identity!.key];
    if (previous == null) return _failure?.userMessage ?? '正在查询账号统计';
    final time = previous.at
        .toLocal()
        .toIso8601String()
        .split('.')
        .first
        .replaceFirst('T', ' ');
    final limit = !isStale &&
            previous.value.deviceLimit > 0 &&
            previous.value.onlineDevices >= previous.value.deviceLimit
        ? '；设备数达到上限，新连接前请先断开其他设备 [DEVICE_LIMIT_REACHED]'
        : '';
    return '${isStale ? '上次数据，暂未更新' : '统计已更新'} · $time'
        '${_failure == null ? '' : '；${_failure!.userMessage}'}$limit';
  }

  void update(
      {required ProxyNode? node,
      required Object? revision,
      required bool active}) {
    final next = _providers.resolve(node);
    final identityChanged = next?.key != _identity?.key;
    if (identityChanged || !identical(revision, _revision)) {
      // List revisions invalidate in-flight work, not account evidence or its
      // retry budget. Sorting and renaming do not change a trusted identity.
      _epoch++;
      _revision = revision;
    }
    if (identityChanged) {
      _identity = next;
      _lastServerTime = _history[next?.key]?.value.serverTime;
      _failure = null;
      final budget = _retryBudgets[next?.key];
      _failures = budget?.failures ?? 0;
      _retryAt = budget?.until ?? Duration.zero;
      _clear();
    }
    if (_active != active) {
      _epoch++;
      _active = active;
      if (!active) {
        _suspended = (elapsed: _now(), wall: _wallNow());
      } else {
        _resume();
        if (_failures == 0 && value == null) _retryAt = Duration.zero;
      }
    }
    _poll?.cancel();
    if (value == null && _value != null) _clear();
    if (_active && _identity != null && !_busy) {
      _schedule(_remainingRetry());
    }
  }

  void _resume() {
    final suspended = _suspended;
    _suspended = null;
    if (suspended == null || _value == null) return;
    // Monotonic expiry remains authoritative. Some OS clocks pause in sleep;
    // wall time may only shorten validity, never renew or extend cached data.
    final wallElapsed = _wallNow().difference(suspended.wall);
    final monotonicElapsed = _now() - suspended.elapsed;
    if (wallElapsed.isNegative || monotonicElapsed.isNegative) {
      _clear();
      return;
    }
    if (wallElapsed > monotonicElapsed) {
      final sleep = wallElapsed - monotonicElapsed;
      _expires -= sleep;
      if (_failures == 0) _retryAt -= sleep;
    }
    _expiry?.cancel();
    final remaining = _expires - _now();
    if (remaining <= Duration.zero) {
      _clear();
    } else {
      _expiry = Timer(remaining, _clear);
    }
  }

  Duration _remainingRetry() {
    final server = _serverRetryUntil[_identity?.retryKey] ?? Duration.zero;
    final until = server > _retryAt ? server : _retryAt;
    return until > _now() ? until - _now() : Duration.zero;
  }

  void _schedule(Duration delay) {
    _poll?.cancel();
    _poll = Timer(delay, _refresh);
  }

  Future<void> _refresh() async {
    if (_disposed || !_active || _identity == null || _busy) return;
    final identity = _identity!;
    final epoch = _epoch;
    final start = _now();
    _busy = true;
    var delay = const Duration(seconds: 10);
    try {
      final result = await _fetch(identity);
      if (_disposed || epoch != _epoch) return;
      final lifetime = Duration(seconds: result.expiresAt - result.serverTime) -
          (_now() - start);
      if (lifetime <= Duration.zero ||
          (_lastServerTime != null && result.serverTime <= _lastServerTime!)) {
        throw const UsageQueryFailure();
      }
      if (_failure != null) _diagnostic('账号统计已恢复');
      _failure = null;
      _lastServerTime = result.serverTime;
      _value = result;
      _history.remove(identity.key);
      _history[identity.key] = (value: result, at: _wallNow());
      if (_history.length > 32) _history.remove(_history.keys.first);
      _expires = _now() + lifetime;
      _failures = 0;
      _retryBudgets.remove(identity.key);
      _serverRetryUntil.remove(identity.retryKey);
      _expiry?.cancel();
      _expiry = Timer(lifetime, _clear);
      notifyListeners();
    } catch (error) {
      if (_disposed) return;
      final failure =
          error is UsageQueryFailure ? error : const UsageQueryFailure();
      // A view change invalidates its result, but not the server's retry limit
      // for that identity. Keep budgets separate even across account switches.
      final failures =
          ((_retryBudgets[identity.key]?.failures ?? 0) + 1).clamp(1, 5);
      delay = Duration(seconds: 15 * (1 << (failures - 1)));
      final retryAfter = failure.retryAfter;
      if (retryAfter != null && retryAfter > Duration.zero) {
        // Only an explicit server limit applies across this account's nodes.
        // Node-specific failures must not delay a different node's query.
        _serverRetryUntil.remove(identity.retryKey);
        _serverRetryUntil[identity.retryKey] = _now() + retryAfter;
        if (_serverRetryUntil.length > 32) {
          _serverRetryUntil.remove(_serverRetryUntil.keys.first);
        }
        if (retryAfter > delay) delay = retryAfter;
      }
      final retryAt = _now() + delay;
      _retryBudgets.remove(identity.key);
      _retryBudgets[identity.key] = (until: retryAt, failures: failures);
      if (_retryBudgets.length > 32) {
        _retryBudgets.remove(_retryBudgets.keys.first);
      }
      if (_identity?.key == identity.key) {
        _failures = failures;
        _retryAt = retryAt;
      }
      if (epoch != _epoch) return;
      if (_failure?.kind != failure.kind) {
        _diagnostic(failure.userMessage);
      }
      _failure = failure;
      _clear();
    } finally {
      _busy = false;
      if (!_disposed && _active && _identity != null) {
        if (epoch == _epoch) _retryAt = _now() + delay;
        _schedule(_remainingRetry());
      }
    }
  }

  void _diagnostic(String message) {
    try {
      onDiagnostic?.call(message);
    } catch (_) {
      // Observers must not invalidate an otherwise complete snapshot.
    }
  }

  void _clear() {
    _expiry?.cancel();
    _value = null;
    _expires = Duration.zero;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _poll?.cancel();
    _expiry?.cancel();
    super.dispose();
  }
}
