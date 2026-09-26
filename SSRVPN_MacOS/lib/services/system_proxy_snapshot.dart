part of 'system_proxy_service.dart';

/// Validates and retires snapshot entries without changing network settings.
extension _MacProxySnapshot on SystemProxyService {
  Map<String, String>? _validatedSavedServiceIdentities(
    Object? value, {
    required List<String> savedServices,
  }) {
    if (value is! Map) {
      _lastError = 'macOS 网络服务稳定标识快照格式无效，已保留现场';
      return null;
    }
    final identities = <String, String>{};
    final seenIDs = <String>{};
    for (final entry in value.entries) {
      final name = entry.key is String ? (entry.key as String).trim() : '';
      final serviceID =
          entry.value is String ? (entry.value as String).trim() : '';
      if (name.isEmpty ||
          serviceID.isEmpty ||
          identities.containsKey(name) ||
          !seenIDs.add(serviceID)) {
        _lastError = 'macOS 网络服务稳定标识快照格式无效，已保留现场';
        return null;
      }
      identities[name] = serviceID;
    }
    final saved = savedServices.toSet();
    if (identities.length != saved.length ||
        !saved.every(identities.containsKey)) {
      _lastError = 'macOS 网络服务稳定标识与代理快照不一致，已保留现场';
      return null;
    }
    return identities;
  }

  void _removeSavedService(
    Map<String, dynamic> raw,
    String service, {
    required bool hasStableIdentities,
  }) {
    raw.remove(service);
    if (!hasStableIdentities) return;
    final identities = raw['_networkServiceIDs'];
    if (identities is Map<String, dynamic>) {
      identities.remove(service);
    } else if (identities is Map) {
      identities.remove(service);
    }
  }

  Map<String, Map<String, dynamic>>? _validatedSavedServiceStates(
    Map<String, dynamic> raw, {
    required bool hasStableIdentities,
  }) {
    final services = <String, Map<String, dynamic>>{};
    for (final entry in raw.entries) {
      if (SystemProxyService._snapshotMetadataKeys.contains(entry.key) &&
          (entry.key != '_networkServiceIDs' || hasStableIdentities)) {
        continue;
      }
      final value = entry.value;
      if (!_isCompleteSavedProxyServiceState(value)) {
        _lastError = '${entry.key}: 保存的代理状态格式无效，已保留现场';
        return null;
      }
      services[entry.key] = value as Map<String, dynamic>;
    }
    if (services.isEmpty) {
      _lastError = '代理恢复快照不包含有效网络服务，已保留现场';
      return null;
    }
    return services;
  }

  bool _isCompleteSavedProxyServiceState(Object? value) =>
      value is Map<String, dynamic> &&
      value.length == 3 &&
      const {'web', 'secureWeb', 'socks'}.containsAll(value.keys) &&
      _isValidProxyState(value['web']) &&
      _isValidProxyState(value['secureWeb']) &&
      _isValidProxyState(value['socks']);

  bool _isValidProxyState(Object? value) {
    if (value is! Map<String, dynamic>) return false;
    if (!const {'enabled', 'server', 'port'}.containsAll(value.keys) ||
        value.length != 3) {
      return false;
    }
    final enabled = value['enabled'];
    final server = value['server'];
    final port = value['port'];
    if (enabled is! bool ||
        server is! String ||
        port is! int ||
        port < 0 ||
        port > 65535) {
      return false;
    }
    return !enabled || (server.trim().isNotEmpty && port > 0);
  }
}
