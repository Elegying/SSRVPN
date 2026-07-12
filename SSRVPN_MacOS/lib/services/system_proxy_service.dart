import 'dart:convert';
import 'dart:io';

import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_macos/src/services/system_proxy_ownership.dart';

/// macOS 系统代理服务。
///
/// 通过 `networksetup` 设置/恢复 HTTP、HTTPS、SOCKS 代理。设置前会记录
/// 原始代理状态，停止连接或下次启动发现残留状态时优先恢复，避免异常退出后
/// 把用户本来配置的代理直接清空。
class SystemProxyService {
  static final SystemProxyService _instance = SystemProxyService._();
  factory SystemProxyService() => _instance;
  SystemProxyService._();

  static const _networkSetupPath = '/usr/sbin/networksetup';
  static const _commandTimeout = Duration(seconds: 4);
  File? _stateFile;
  bool _proxyEnabled = false;
  bool _recoveryPending = false;
  String? _ownedProxyHost;
  int? _ownedProxyPort;
  String? _lastError;

  bool get isProxyEnabled => _proxyEnabled;
  bool get recoveryPending => _recoveryPending;
  String? get lastError => _lastError;

  Future<void> initialize(String configDir) async {
    _stateFile = File('$configDir${Platform.pathSeparator}system_proxy.json');
    final file = _stateFile;
    if (file != null && await file.exists()) {
      _recoveryPending = !await clearSystemProxy();
    }
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
    if (host.trim().isEmpty || port < 1 || port > 65535) {
      _lastError = '代理地址或端口无效: $host:$port';
      return false;
    }
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
      _ownedProxyHost = host;
      _ownedProxyPort = port;
      return true;
    } catch (e) {
      final originalError = '系统代理设置失败: $e';
      await clearSystemProxy();
      _lastError = originalError;
      return false;
    }
  }

  Future<bool> clearSystemProxy() async {
    if (!Platform.isMacOS) return false;
    _lastError = null;
    try {
      final file = _stateFile;
      if (file == null || !await file.exists()) {
        _forgetOwnership();
        _recoveryPending = false;
        return true;
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
    if (await file.exists()) {
      _recoveryPending = true;
      throw StateError('已有未恢复的系统代理备份');
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
    if (file == null || !await file.exists()) return false;

    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return false;

      final ownedHost = raw['_ownedProxyHost']?.toString();
      final ownedPort = int.tryParse(raw['_ownedProxyPort']?.toString() ?? '');
      if (ownedHost == null || ownedHost.isEmpty || ownedPort == null) {
        // Legacy state cannot prove ownership. Preserve current user settings.
        await file.delete();
        return true;
      }

      final savedServices = raw.keys
          .map((key) => key.toString())
          .where((service) => !service.startsWith('_'))
          .toList(growable: false);
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
        final value = raw[service];
        if (value is! Map) {
          failures.add('$service: 保存的代理状态格式无效');
          continue;
        }
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
      return;
    }
    await _restoreProxyState(
      service,
      value,
      setCommand: setCommand,
      stateCommand: stateCommand,
    );
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

  Future<void> _checkedRun(List<String> args) async {
    final result = await _runNetworkSetup(args);
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw Exception(
        stderr.isEmpty ? 'networksetup ${args.join(' ')} 失败' : stderr,
      );
    }
  }

  Future<ProcessResult> _runNetworkSetup(List<String> args) =>
      TimedProcessRunner.run(
        _networkSetupPath,
        args,
        timeout: _commandTimeout,
        timeoutStderr: 'networksetup 命令超时',
      );

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
