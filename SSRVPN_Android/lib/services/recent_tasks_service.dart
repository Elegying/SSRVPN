import 'package:flutter/services.dart';

/// Native storage owns this Android-only preference, including cold startup.
class RecentTasksService {
  const RecentTasksService();

  static const _channel = MethodChannel('com.ssrvpn/recent_tasks');

  Future<bool> read() => _invoke('getEnabled');

  Future<bool> setEnabled(bool enabled) => _invoke('setEnabled', enabled);

  Future<bool> _invoke(String method, [bool? enabled]) async {
    final result = await _channel.invokeMethod<bool>(method, enabled);
    if (result == null) throw StateError('RECENTS_VISIBILITY_UNAVAILABLE');
    return result;
  }
}
