import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  static const _ownProxyHost = '127.0.0.1';

  File? _stateFile;
  bool _proxyEnabled = false;
  String? _lastError;

  bool get isProxyEnabled => _proxyEnabled;
  String? get lastError => _lastError;

  Future<void> initialize(String configDir) async {
    _stateFile = File('$configDir${Platform.pathSeparator}system_proxy.json');
    final file = _stateFile;
    if (file != null && await file.exists()) {
      await clearSystemProxy();
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
      final lines = result.stdout.toString().split('\n');
      final services = <String>[];
      for (final line in lines) {
        final s = line.trim();
        if (s.isEmpty) continue;
        if (s.startsWith('An asterisk')) continue;
        if (s.startsWith('*')) continue;
        services.add(s);
      }
      return services;
    } catch (e) {
      _lastError = '读取网络服务列表失败: $e';
      return [];
    }
  }

  Future<bool> setSystemProxy(String host, int port) async {
    if (!Platform.isMacOS) return false;
    _lastError = null;
    try {
      final services = await _listNetworkServices();
      if (services.isEmpty) {
        _lastError ??= '没有找到可用的 macOS 网络服务';
        return false;
      }

      await _saveCurrentStateIfNeeded(services);

      for (final svc in services) {
        await _checkedRun(['-setwebproxy', svc, host, '$port']);
        await _checkedRun(['-setwebproxystate', svc, 'on']);
        await _checkedRun(['-setsecurewebproxy', svc, host, '$port']);
        await _checkedRun(['-setsecurewebproxystate', svc, 'on']);
        await _checkedRun(['-setsocksfirewallproxy', svc, host, '$port']);
        await _checkedRun(['-setsocksfirewallproxystate', svc, 'on']);
      }
      _proxyEnabled = true;
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
      final restored = await _restoreSavedState();
      if (restored) {
        _proxyEnabled = false;
        return true;
      }

      final services = await _listNetworkServices();
      for (final svc in services) {
        if (_isOwnProxy(await _readProxyState(svc, '-getwebproxy'))) {
          await _checkedRun(['-setwebproxystate', svc, 'off']);
        }
        if (_isOwnProxy(await _readProxyState(svc, '-getsecurewebproxy'))) {
          await _checkedRun(['-setsecurewebproxystate', svc, 'off']);
        }
        if (_isOwnProxy(await _readProxyState(svc, '-getsocksfirewallproxy'))) {
          await _checkedRun(['-setsocksfirewallproxystate', svc, 'off']);
        }
      }
      _proxyEnabled = false;
      return true;
    } catch (e) {
      _lastError = '系统代理恢复失败: $e';
      return false;
    }
  }

  Future<void> _saveCurrentStateIfNeeded(List<String> services) async {
    final file = _stateFile;
    if (file == null || await file.exists()) return;

    final states = <String, dynamic>{};
    for (final svc in services) {
      final webState = await _readProxyState(svc, '-getwebproxy');
      final secureWebState = await _readProxyState(svc, '-getsecurewebproxy');
      final socksState = await _readProxyState(svc, '-getsocksfirewallproxy');

      // 如果当前代理是 SSRVPN 自己设置的（127.0.0.1），不要保存为“原始状态”
      // 否则恢复时会恢复到我们自己的代理地址，导致网络中断
      states[svc] = {
        'web': _isOwnProxy(webState)
            ? {'enabled': false, 'server': '', 'port': 0}
            : webState,
        'secureWeb': _isOwnProxy(secureWebState)
            ? {'enabled': false, 'server': '', 'port': 0}
            : secureWebState,
        'socks': _isOwnProxy(socksState)
            ? {'enabled': false, 'server': '', 'port': 0}
            : socksState,
      };
    }
    await _writeStringAtomically(file, jsonEncode(states));
  }

  /// 判断代理是否是 SSRVPN 自己设置的
  bool _isOwnProxy(Map<String, dynamic> state) {
    final server = state['server']?.toString() ?? '';
    return server == _ownProxyHost;
  }

  Future<bool> _restoreSavedState() async {
    final file = _stateFile;
    if (file == null || !await file.exists()) return false;

    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return false;

      for (final entry in raw.entries) {
        final service = entry.key.toString();
        final value = entry.value;
        if (value is! Map) continue;
        await _restoreProxyState(
          service,
          value['web'],
          setCommand: '-setwebproxy',
          stateCommand: '-setwebproxystate',
        );
        await _restoreProxyState(
          service,
          value['secureWeb'],
          setCommand: '-setsecurewebproxy',
          stateCommand: '-setsecurewebproxystate',
        );
        await _restoreProxyState(
          service,
          value['socks'],
          setCommand: '-setsocksfirewallproxy',
          stateCommand: '-setsocksfirewallproxystate',
        );
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
    final text = result.stdout.toString();
    return {
      'enabled': _readLineValue(text, 'Enabled').toLowerCase() == 'yes',
      'server': _readLineValue(text, 'Server'),
      'port': int.tryParse(_readLineValue(text, 'Port')) ?? 0,
    };
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

  Future<ProcessResult> _runNetworkSetup(List<String> args) async {
    Process? process;
    try {
      process = await Process.start(_networkSetupPath, args);
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        _commandTimeout,
        onTimeout: () {
          process?.kill(ProcessSignal.sigkill);
          return 124;
        },
      );
      final stdout = await stdoutFuture;
      final stderr = exitCode == 124 ? 'networksetup 命令超时' : await stderrFuture;
      return ProcessResult(process.pid, exitCode, stdout, stderr);
    } catch (_) {
      process?.kill(ProcessSignal.sigkill);
      rethrow;
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
}
