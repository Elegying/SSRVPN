import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_macos/src/services/system_proxy_ownership.dart';

typedef MacNetworkSetupRunner = Future<ProcessResult> Function(
  List<String> arguments,
);
typedef MacEffectiveProxyRunner = Future<ProcessResult> Function();
typedef MacProxyLifecycleBegin = Future<String> Function();
typedef MacProxyLifecycleEnd = Future<bool> Function(String token);

/// macOS 系统代理服务。
///
/// 通过 `networksetup` 设置/恢复 HTTP、HTTPS、SOCKS 代理。设置前会记录
/// 原始代理状态，停止连接或下次启动发现残留状态时优先恢复，避免异常退出后
/// 把用户本来配置的代理直接清空。
class SystemProxyService {
  SystemProxyService({
    MacNetworkSetupRunner? networkSetupRunner,
    MacEffectiveProxyRunner? effectiveProxyRunner,
    MacProxyLifecycleBegin? beginProxyLifecycleTransaction,
    MacProxyLifecycleEnd? endProxyLifecycleTransaction,
  })  : _networkSetupRunner = networkSetupRunner,
        _effectiveProxyRunner = effectiveProxyRunner,
        _beginProxyLifecycleTransaction = beginProxyLifecycleTransaction,
        _endProxyLifecycleTransaction = endProxyLifecycleTransaction;

  static const _networkSetupPath = '/usr/sbin/networksetup';
  static const _scutilPath = '/usr/sbin/scutil';
  static const _coreProcessChannel = MethodChannel('ssrvpn/core_process');
  static const _commandTimeout = Duration(seconds: 4);
  static const _maxStateFileBytes = 1024 * 1024;
  static const _groupOrOtherWriteMask = 0x12;
  static const _snapshotMetadataKeys = {
    '_ownedProxyHost',
    '_ownedProxyPort',
    '_ownerPid',
  };
  final MacNetworkSetupRunner? _networkSetupRunner;
  final MacEffectiveProxyRunner? _effectiveProxyRunner;
  final MacProxyLifecycleBegin? _beginProxyLifecycleTransaction;
  final MacProxyLifecycleEnd? _endProxyLifecycleTransaction;
  File? _stateFile;
  Future<bool>? _clearSystemProxyInFlight;
  bool _proxyEnabled = false;
  bool _recoveryPending = false;
  bool _ownershipChangedSinceLastAcquisition = false;
  String? _ownedProxyHost;
  int? _ownedProxyPort;
  String? _lastError;

  bool get isProxyEnabled => _proxyEnabled;
  bool get recoveryPending => _recoveryPending;
  bool get ownershipChangedSinceLastAcquisition =>
      _ownershipChangedSinceLastAcquisition;
  String? get lastError => _lastError;

  /// Verifies the effective proxy of the currently active macOS network
  /// service without changing it. `scutil --proxy` follows service priority,
  /// so switching to a newly-created service cannot silently bypass SSRVPN.
  Future<SystemProxyOwnershipStatus> currentSystemProxyOwnershipStatus() async {
    if (!Platform.isMacOS) return SystemProxyOwnershipStatus.unavailable;
    final ownedHost = _ownedProxyHost;
    final ownedPort = _ownedProxyPort;
    if (!_proxyEnabled ||
        ownedHost == null ||
        ownedHost.isEmpty ||
        ownedPort == null ||
        ownedPort < 1 ||
        ownedPort > 65535) {
      _lastError = 'macOS 系统代理所有权信息不可用';
      return SystemProxyOwnershipStatus.unavailable;
    }

    try {
      final result = await _runEffectiveProxyProbe();
      if (result.exitCode != 0) {
        final stderr = result.stderr.toString().trim();
        _lastError = stderr.isEmpty ? '无法读取 macOS 当前系统代理' : stderr;
        return SystemProxyOwnershipStatus.unavailable;
      }
      final values = _parseEffectiveProxy(result.stdout.toString());
      final owned = _effectiveProxyEntryIsOwned(
            values,
            enableKey: 'HTTPEnable',
            hostKey: 'HTTPProxy',
            portKey: 'HTTPPort',
            ownedHost: ownedHost,
            ownedPort: ownedPort,
          ) &&
          _effectiveProxyEntryIsOwned(
            values,
            enableKey: 'HTTPSEnable',
            hostKey: 'HTTPSProxy',
            portKey: 'HTTPSPort',
            ownedHost: ownedHost,
            ownedPort: ownedPort,
          ) &&
          _effectiveProxyEntryIsOwned(
            values,
            enableKey: 'SOCKSEnable',
            hostKey: 'SOCKSProxy',
            portKey: 'SOCKSPort',
            ownedHost: ownedHost,
            ownedPort: ownedPort,
          );
      if (!owned) {
        _lastError = 'macOS 当前网络服务的系统代理已被关闭或修改';
        return SystemProxyOwnershipStatus.externallyChanged;
      }
      _lastError = null;
      return SystemProxyOwnershipStatus.owned;
    } catch (error) {
      _lastError = '读取 macOS 当前系统代理失败: $error';
      return SystemProxyOwnershipStatus.unavailable;
    }
  }

  Future<bool> isCurrentSystemProxyOwned() async =>
      await currentSystemProxyOwnershipStatus() ==
      SystemProxyOwnershipStatus.owned;

  Future<void> initialize(String configDir) async {
    _stateFile = File('$configDir${Platform.pathSeparator}system_proxy.json');
    if (!Platform.isMacOS) {
      _recoveryPending = false;
      return;
    }
    _recoveryPending = !await clearSystemProxy();
  }

  /// 获取所有可用的网络服务名称（Wi-Fi、Ethernet 等）。
  Future<List<String>> _listNetworkServices() async {
    try {
      final result = await _runNetworkSetup(['-listallnetworkservices']);
      if (result.exitCode != 0) {
        _lastError = '无法读取网络服务列表: ${result.stderr}'.trim();
        return [];
      }
      return parseMacNetworkServiceList(result.stdout.toString());
    } catch (e) {
      _lastError = '读取网络服务列表失败: $e';
      return [];
    }
  }

  Future<bool> setSystemProxy(String host, int port) async {
    if (!Platform.isMacOS) return false;
    _lastError = null;
    final normalizedHost = host.trim();
    if (normalizedHost.isEmpty || port < 1 || port > 65535) {
      _lastError = '代理地址或端口无效: $host:$port';
      return false;
    }
    return _runWithNativeProxyLifecycleLease(
      () => _setSystemProxyOnce(normalizedHost, port),
    );
  }

  Future<bool> _setSystemProxyOnce(String host, int port) async {
    if (_recoveryPending) {
      _lastError = '系统代理仍有未恢复的旧状态，请查看运行日志';
      return false;
    }
    try {
      if (_proxyEnabled &&
          (_ownedProxyHost != host || _ownedProxyPort != port)) {
        if (!await clearSystemProxy()) return false;
        _lastError = null;
      }

      final services = await _listNetworkServices();
      if (services.isEmpty) {
        _lastError ??= '没有找到可用的 macOS 网络服务';
        return false;
      }
      String? reservedService;
      for (final service in services) {
        if (_snapshotMetadataKeys.contains(service)) {
          reservedService = service;
          break;
        }
      }
      if (reservedService != null) {
        _lastError = '网络服务名称与代理快照保留字段冲突: $reservedService';
        return false;
      }

      await _saveCurrentStateIfNeeded(services, host, port);

      for (final svc in services) {
        await _checkedRun(['-setwebproxy', svc, host, '$port']);
        await _checkedRun(['-setwebproxystate', svc, 'on']);
        await _checkedRun(['-setsecurewebproxy', svc, host, '$port']);
        await _checkedRun(['-setsecurewebproxystate', svc, 'on']);
        await _checkedRun(['-setsocksfirewallproxy', svc, host, '$port']);
        await _checkedRun(['-setsocksfirewallproxystate', svc, 'on']);
      }
      _proxyEnabled = true;
      _recoveryPending = false;
      _ownershipChangedSinceLastAcquisition = false;
      _ownedProxyHost = host;
      _ownedProxyPort = port;
      return true;
    } catch (e) {
      final originalError = '系统代理设置失败: $e';
      await _clearSystemProxyOnce();
      _lastError = originalError;
      return false;
    }
  }

  Future<bool> clearSystemProxy() {
    if (!Platform.isMacOS) return Future.value(false);
    return _clearSystemProxyInFlight ??= _runClearSystemProxy();
  }

  Future<bool> _runClearSystemProxy() async {
    try {
      return await _runWithNativeProxyLifecycleLease(_clearSystemProxyOnce);
    } finally {
      _clearSystemProxyInFlight = null;
    }
  }

  Future<bool> _runWithNativeProxyLifecycleLease(
    Future<bool> Function() operation,
  ) async {
    String? token;
    var succeeded = false;
    try {
      token = await _beginNativeProxyLifecycleTransaction();
      if (token.isEmpty) throw StateError('原生代理生命周期令牌无效');
      succeeded = await operation();
    } catch (error) {
      _lastError ??= '无法锁定 macOS 代理生命周期: $error';
      succeeded = false;
    } finally {
      if (token != null) {
        var ended = false;
        Object? lastEndError;
        for (var attempt = 0; attempt < 3 && !ended; attempt++) {
          try {
            ended = await _endNativeProxyLifecycleTransaction(token);
          } catch (error) {
            lastEndError = error;
          }
        }
        if (!ended) {
          _lastError = '无法释放 macOS 代理生命周期令牌: '
              '${lastEndError ?? '令牌不匹配'}';
          succeeded = false;
        }
      }
    }
    return succeeded;
  }

  Future<String> _beginNativeProxyLifecycleTransaction() async {
    final begin = _beginProxyLifecycleTransaction;
    if (begin != null) return begin();
    final token = await _coreProcessChannel.invokeMethod<String>(
      'beginProxyLifecycleTransaction',
    );
    if (token == null || token.isEmpty) {
      throw StateError('原生代理生命周期令牌无效');
    }
    return token;
  }

  Future<bool> _endNativeProxyLifecycleTransaction(String token) async {
    final end = _endProxyLifecycleTransaction;
    if (end != null) return end(token);
    return await _coreProcessChannel.invokeMethod<bool>(
          'endProxyLifecycleTransaction',
          {'token': token},
        ) ==
        true;
  }

  Future<bool> _clearSystemProxyOnce() async {
    _lastError = null;
    try {
      final file = _stateFile;
      if (file == null) {
        _forgetOwnership();
        _recoveryPending = false;
        return true;
      }
      final stateFileStatus = await _inspectStateFile(file);
      if (stateFileStatus == _ProxyStateFileStatus.missing) {
        _forgetOwnership();
        _recoveryPending = false;
        return true;
      }
      if (stateFileStatus == _ProxyStateFileStatus.unsafe) {
        _recoveryPending = true;
        return false;
      }

      final restored = await _restoreSavedState();
      if (restored) {
        _forgetOwnership();
        _recoveryPending = false;
        return true;
      }
      _recoveryPending = true;
      return false;
    } catch (e) {
      _recoveryPending = true;
      _lastError = '系统代理恢复失败: $e';
      return false;
    }
  }

  Future<void> _saveCurrentStateIfNeeded(
    List<String> services,
    String ownedHost,
    int ownedPort,
  ) async {
    final file = _stateFile;
    if (file == null) {
      throw StateError('SystemProxyService has not been initialized');
    }
    final stateFileStatus = await _inspectStateFile(file);
    if (stateFileStatus != _ProxyStateFileStatus.missing) {
      _recoveryPending = true;
      throw StateError(
        stateFileStatus == _ProxyStateFileStatus.safe
            ? '已有未恢复的系统代理备份'
            : _lastError ?? '代理恢复状态路径不安全',
      );
    }
    if (services.any(_snapshotMetadataKeys.contains)) {
      throw StateError('网络服务名称与代理快照保留字段冲突');
    }

    final states = <String, dynamic>{
      '_ownedProxyHost': ownedHost,
      '_ownedProxyPort': ownedPort,
      '_ownerPid': pid,
    };
    for (final svc in services) {
      final webState = await _readProxyState(svc, '-getwebproxy');
      final secureWebState = await _readProxyState(svc, '-getsecurewebproxy');
      final socksState = await _readProxyState(svc, '-getsocksfirewallproxy');

      states[svc] = {
        'web': webState,
        'secureWeb': secureWebState,
        'socks': socksState,
      };
    }
    await _writeStringAtomically(file, jsonEncode(states));
    _ownedProxyHost = ownedHost;
    _ownedProxyPort = ownedPort;
  }

  Future<bool> _restoreSavedState() async {
    final file = _stateFile;
    if (file == null) return false;

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        _lastError = '代理恢复快照格式无效，已保留现场';
        return false;
      }
      final raw = decoded;

      final rawOwnedHost = raw['_ownedProxyHost'];
      final rawOwnedPort = raw['_ownedProxyPort'];
      final rawOwnerPid = raw['_ownerPid'];
      final ownedHost = rawOwnedHost is String ? rawOwnedHost.trim() : null;
      final ownedPort = rawOwnedPort is int ? rawOwnedPort : null;
      if (ownedHost == null ||
          ownedHost.isEmpty ||
          ownedPort == null ||
          ownedPort < 1 ||
          ownedPort > 65535 ||
          (rawOwnerPid != null && (rawOwnerPid is! int || rawOwnerPid <= 1))) {
        _lastError = '无法确认代理归属，已保留恢复快照并阻止核心清理';
        return false;
      }

      final savedServiceStates = _validatedSavedServiceStates(raw);
      if (savedServiceStates == null) return false;
      final savedServices = savedServiceStates.keys.toList(growable: false);
      final currentServices = await _listNetworkServices();
      if (savedServices.isNotEmpty && currentServices.isEmpty) {
        _lastError ??= '无法确认当前 macOS 网络服务，稍后重试恢复';
        return false;
      }
      final services = restorableMacNetworkServices(
        savedServices: savedServices,
        currentServices: currentServices,
      );
      final pendingServices = pendingMacNetworkServices(
        savedServices: savedServices,
        currentServices: currentServices,
      );
      final failures = <String>[];
      final resolvedServices = <String>[];
      for (final service in services) {
        final value = savedServiceStates[service]!;
        try {
          await _restoreProxyStateIfOwned(
            service,
            value['web'],
            ownedHost: ownedHost,
            ownedPort: ownedPort,
            getCommand: '-getwebproxy',
            setCommand: '-setwebproxy',
            stateCommand: '-setwebproxystate',
          );
          await _restoreProxyStateIfOwned(
            service,
            value['secureWeb'],
            ownedHost: ownedHost,
            ownedPort: ownedPort,
            getCommand: '-getsecurewebproxy',
            setCommand: '-setsecurewebproxy',
            stateCommand: '-setsecurewebproxystate',
          );
          await _restoreProxyStateIfOwned(
            service,
            value['socks'],
            ownedHost: ownedHost,
            ownedPort: ownedPort,
            getCommand: '-getsocksfirewallproxy',
            setCommand: '-setsocksfirewallproxy',
            stateCommand: '-setsocksfirewallproxystate',
          );
          resolvedServices.add(service);
        } catch (error) {
          failures.add('$service: $error');
        }
      }
      for (final service in resolvedServices) {
        raw.remove(service);
      }
      final mustRetry = failures.isNotEmpty || pendingServices.isNotEmpty;
      if (mustRetry) {
        await _writeStringAtomically(file, jsonEncode(raw));
      }
      if (failures.isNotEmpty) {
        _lastError = '部分 macOS 网络服务恢复失败: ${failures.join('；')}';
        return false;
      }
      if (pendingServices.isNotEmpty) {
        _lastError = '以下 macOS 网络服务暂不可用，将在下次启动时继续恢复: '
            '${pendingServices.join('、')}';
        return false;
      }
      await file.delete();
      return true;
    } catch (e) {
      _lastError = '读取代理恢复状态失败: $e';
      return false;
    }
  }

  Map<String, Map<String, dynamic>>? _validatedSavedServiceStates(
    Map<String, dynamic> raw,
  ) {
    final services = <String, Map<String, dynamic>>{};
    for (final entry in raw.entries) {
      if (_snapshotMetadataKeys.contains(entry.key)) continue;
      final value = entry.value;
      if (value is! Map<String, dynamic> ||
          !const {'web', 'secureWeb', 'socks'}.containsAll(value.keys) ||
          value.length != 3 ||
          !_isValidProxyState(value['web']) ||
          !_isValidProxyState(value['secureWeb']) ||
          !_isValidProxyState(value['socks'])) {
        _lastError = '${entry.key}: 保存的代理状态格式无效，已保留现场';
        return null;
      }
      services[entry.key] = value;
    }
    if (services.isEmpty) {
      _lastError = '代理恢复快照不包含有效网络服务，已保留现场';
      return null;
    }
    return services;
  }

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

  Future<Map<String, dynamic>> _readProxyState(
    String service,
    String command,
  ) async {
    final result = await _runNetworkSetup([command, service]);
    if (result.exitCode != 0) {
      throw Exception('读取 $service 代理状态失败: ${result.stderr}');
    }
    final text = result.stdout.toString();
    return {
      'enabled': _readLineValue(text, 'Enabled').toLowerCase() == 'yes',
      'server': _readLineValue(text, 'Server'),
      'port': int.tryParse(_readLineValue(text, 'Port')) ?? 0,
    };
  }

  Future<void> _restoreProxyStateIfOwned(
    String service,
    Object? value, {
    required String ownedHost,
    required int ownedPort,
    required String getCommand,
    required String setCommand,
    required String stateCommand,
  }) async {
    final current = await _readProxyState(service, getCommand);
    if (!isOwnedMacProxy(
      enabled: current['enabled'] == true,
      server: current['server']?.toString() ?? '',
      port: int.tryParse(current['port']?.toString() ?? '') ?? 0,
      ownedHost: ownedHost,
      ownedPort: ownedPort,
    )) {
      if (!_proxyStatesEquivalent(current, value)) {
        _ownershipChangedSinceLastAcquisition = true;
      }
      return;
    }
    await _restoreProxyState(
      service,
      value,
      setCommand: setCommand,
      stateCommand: stateCommand,
    );
  }

  bool _proxyStatesEquivalent(Map<String, dynamic> current, Object? saved) {
    final expected = saved is Map ? saved : const {};
    final currentEnabled = current['enabled'] == true;
    final expectedEnabled = expected['enabled'] == true;
    if (currentEnabled != expectedEnabled) return false;
    if (!currentEnabled) return true;
    return (current['server']?.toString().trim() ?? '') ==
            (expected['server']?.toString().trim() ?? '') &&
        (int.tryParse(current['port']?.toString() ?? '') ?? 0) ==
            (int.tryParse(expected['port']?.toString() ?? '') ?? 0);
  }

  Future<void> _restoreProxyState(
    String service,
    Object? value, {
    required String setCommand,
    required String stateCommand,
  }) async {
    final state = value is Map ? value : const {};
    final enabled = state['enabled'] == true;
    final server = state['server']?.toString() ?? '';
    final port = int.tryParse(state['port']?.toString() ?? '') ?? 0;

    if (enabled && server.isNotEmpty && port > 0) {
      await _checkedRun([setCommand, service, server, '$port']);
      await _checkedRun([stateCommand, service, 'on']);
    } else {
      await _checkedRun([stateCommand, service, 'off']);
    }
  }

  String _readLineValue(String text, String key) {
    final prefix = '$key:';
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith(prefix)) {
        return trimmed.substring(prefix.length).trim();
      }
    }
    return '';
  }

  Map<String, String> _parseEffectiveProxy(String text) {
    final values = <String, String>{};
    final entryPattern = RegExp(
      r'^\s*([A-Za-z][A-Za-z0-9]*)\s*:\s*(.*?)\s*$',
    );
    for (final line in text.split('\n')) {
      final match = entryPattern.firstMatch(line);
      if (match != null) values[match.group(1)!] = match.group(2)!;
    }
    return values;
  }

  bool _effectiveProxyEntryIsOwned(
    Map<String, String> values, {
    required String enableKey,
    required String hostKey,
    required String portKey,
    required String ownedHost,
    required int ownedPort,
  }) =>
      isOwnedMacProxy(
        enabled: values[enableKey] == '1',
        server: values[hostKey] ?? '',
        port: int.tryParse(values[portKey] ?? '') ?? 0,
        ownedHost: ownedHost,
        ownedPort: ownedPort,
      );

  Future<ProcessResult> _runEffectiveProxyProbe() {
    final runner = _effectiveProxyRunner;
    if (runner != null) return runner();
    return TimedProcessRunner.run(
      _scutilPath,
      const ['--proxy'],
      timeout: _commandTimeout,
      timeoutStderr: 'scutil --proxy 命令超时',
    );
  }

  Future<void> _checkedRun(List<String> args) async {
    final result = await _runNetworkSetup(args);
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw Exception(
        stderr.isEmpty ? 'networksetup ${args.join(' ')} 失败' : stderr,
      );
    }
  }

  Future<ProcessResult> _runNetworkSetup(List<String> args) {
    final runner = _networkSetupRunner;
    if (runner != null) return runner(args);
    return TimedProcessRunner.run(
      _networkSetupPath,
      args,
      timeout: _commandTimeout,
      timeoutStderr: 'networksetup 命令超时',
    );
  }

  Future<_ProxyStateFileStatus> _inspectStateFile(File file) async {
    try {
      final type = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        return _ProxyStateFileStatus.missing;
      }
      if (type != FileSystemEntityType.file) {
        _lastError = '代理恢复状态路径不是安全的普通文件，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }

      final stat = await file.stat();
      final typeAfterStat = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      const fileTypeMask = 0xF000;
      const regularFileType = 0x8000;
      if (typeAfterStat != FileSystemEntityType.file ||
          stat.mode & fileTypeMask != regularFileType) {
        _lastError = '代理恢复状态路径不是安全的普通文件，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }
      if (stat.size > _maxStateFileBytes) {
        _lastError = '代理恢复状态超过 1 MiB 安全上限，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }
      if (stat.mode & _groupOrOtherWriteMask != 0) {
        _lastError = '代理恢复状态文件为 group/other 可写，已保留现场';
        return _ProxyStateFileStatus.unsafe;
      }
      return _ProxyStateFileStatus.safe;
    } catch (error) {
      _lastError = '无法安全检查代理恢复状态，已保留现场: $error';
      return _ProxyStateFileStatus.unsafe;
    }
  }

  Future<void> _writeStringAtomically(File file, String content) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(content, flush: true);
    await temp.rename(file.path);
  }

  void _forgetOwnership() {
    _proxyEnabled = false;
    _ownedProxyHost = null;
    _ownedProxyPort = null;
  }
}

enum _ProxyStateFileStatus { missing, safe, unsafe }
