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
      Duration Function()? elapsed})
      : _providers = providers ?? AccountUsageProviders.configured,
        _fetch = fetch ?? const AccountUsageClient().fetch {
    final clock = Stopwatch()..start();
    _now = elapsed ?? (() => clock.elapsed);
  }
  final AccountUsageProviders _providers;
  final Future<AccountUsage> Function(UsageIdentity) _fetch;
  late final Duration Function() _now;
  UsageIdentity? _identity;
  Object? _revision;
  AccountUsage? _value;
  Duration _expires = Duration.zero;
  Timer? _poll, _expiry;
  bool _active = false, _busy = false, _disposed = false;
  int _epoch = 0, _failures = 0;
  int? _lastServerTime;
  Duration _retryAt = Duration.zero;

  AccountUsage? get value => _now() < _expires ? _value : null;

  void update(
      {required ProxyNode? node,
      required Object? revision,
      required bool active}) {
    final next = _providers.resolve(node);
    final changed =
        next?.key != _identity?.key || !identical(revision, _revision);
    if (changed) {
      _epoch++;
      _identity = next;
      _revision = revision;
      _lastServerTime = null;
      _failures = 0;
      _retryAt = Duration.zero;
      _clear();
    }
    if (_active != active) {
      _epoch++;
      _active = active;
      // Some OS monotonic clocks pause in deep sleep. Never restore pre-suspend data.
      if (!active) _clear();
    }
    _poll?.cancel();
    if (value == null && _value != null) _clear();
    if (_active && _identity != null && !_busy) {
      _schedule(changed ? Duration.zero : _remainingRetry());
    }
  }

  Duration _remainingRetry() =>
      _retryAt > _now() ? _retryAt - _now() : Duration.zero;

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
      _lastServerTime = result.serverTime;
      _value = result;
      _expires = _now() + lifetime;
      _failures = 0;
      _expiry?.cancel();
      _expiry = Timer(lifetime, _clear);
      notifyListeners();
    } catch (error) {
      if (_disposed || epoch != _epoch) return;
      _clear();
      _failures = (_failures + 1).clamp(1, 5);
      delay = Duration(seconds: 15 * (1 << (_failures - 1)));
      if (error is UsageQueryFailure &&
          error.retryAfter != null &&
          error.retryAfter! > delay) {
        delay = error.retryAfter!;
      }
    } finally {
      _busy = false;
      if (!_disposed && _active && _identity != null) {
        if (epoch == _epoch) _retryAt = _now() + delay;
        _schedule(_remainingRetry());
      }
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
