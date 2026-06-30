import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:yaml/yaml.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/utils/log_redactor.dart';
import 'package:ssrvpn_shared/utils/private_node_latency_policy.dart';
import '../models/app_settings.dart';
import 'system_proxy_service.dart';

/// Clash Meta 核心管理服务 (Windows 版)
///
/// 通过 spawn mihomo.exe 子进程启动核心，使用 REST API 控制。
/// 支持 TUN 模式（需管理员权限）和系统代理模式。
class ClashService {
  Process? _coreProcess;
  Timer? _statusTimer;
  Future<bool>? _startOperation;
  Future<void>? _stopOperation;
  bool _isRunning = false;
  bool _stoppingCore = false;
  String? _lastHealthCheckError;
  String? _lastStartError;
  String? _startupDisabledReason;
  int _consecutiveHealthCheckFailures = 0;
  static const int _maxConsecutiveHealthCheckFailures = 3;
  static const String _geoProxyGroupName = 'SSRVPN-GEO';
  static const List<String> _geoLookupHosts = [
    'api.country.is',
    'ipinfo.io',
    'ifconfig.co',
  ];

  AppSettings _settings = AppSettings();
  String _corePath = '';
  String _configDir = '';
  String _configPath = '';
  String _logBuffer = '';
  File? _logFile;
  Future<void> _pendingLogWrite = Future<void>.value();
  final HttpClient _directHttpClient = _createDirectHttpClient();
  late final http.Client _apiClient = IOClient(_directHttpClient);

  final SystemProxyService _proxyService = SystemProxyService();

  final Set<VoidCallback> _statusListeners = {};
  void Function(String message)? onLog;

  bool get isRunning => _isRunning;
  String get recentLogs => _logBuffer;
  String get configDir => _configDir;
  String get logPath => _logFile?.path ?? '';
  String? get lastStartError => _lastStartError;
  String? get startupDisabledReason => _startupDisabledReason;
  bool get isStartupDisabled => _startupDisabledReason != null;
  int get runtimeProxyPort => _settings.proxyPort;
  int get runtimeSocksPort => _settings.socksPort;
  int get runtimeApiPort => _settings.apiPort;

  static HttpClient _createDirectHttpClient() {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 2);
    return client;
  }

  void updateSettings(AppSettings settings) {
    _settings = settings;
  }

  void disableStartup(String reason) {
    _startupDisabledReason = reason;
    _lastStartError = reason;
    _log(reason);
  }

  /// 初始化服务
  Future<void> init(
    AppSettings settings, {
    String? dataDir,
    String? storageNotice,
    bool skipCoreProbes = false,
  }) async {
    _settings = settings;
    _startupDisabledReason = null;

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    _configDir = dataDir ?? '$exeDir${Platform.pathSeparator}ssrvpn';
    _configPath = '$_configDir${Platform.pathSeparator}config.yaml';
    _corePath = '$exeDir${Platform.pathSeparator}mihomo.exe';
    await Directory(_configDir).create(recursive: true);
    _logFile = File('$_configDir${Platform.pathSeparator}ssrvpn.log');
    await _rotateLogFile();
    await _proxyService.initialize(_configDir);
    if (!skipCoreProbes) {
      await _terminateOrphanedCores();
    }

    _log('系统: ${Platform.operatingSystemVersion}');
    _log('程序路径: ${Platform.resolvedExecutable}');
    _log('配置目录: $_configDir');
    _log('核心路径: $_corePath');
    _log('诊断日志: ${_logFile!.path}');
    if (storageNotice != null && storageNotice.isNotEmpty) {
      _log('⚠️ $storageNotice');
    }
    if (_proxyService.lastError != null) {
      _log('⚠️ ${_proxyService.lastError}');
    }

    // 验证核心文件
    final coreFile = File(_corePath);
    if (await coreFile.exists()) {
      final size = await coreFile.length();
      _log('✅ 核心文件存在: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
      if (!skipCoreProbes) {
        await _logCoreVersion();
      }
    } else {
      _log('❌ 核心文件不存在: $_corePath');
      _log('请将 mihomo.exe 放到应用目录下');
    }

    // 预下载 MMDB 文件
    if (!skipCoreProbes) {
      await _ensureMMDB();
    }
  }

  Future<void> _rotateLogFile() async {
    final logFile = _logFile;
    if (logFile == null || !await logFile.exists()) return;
    if (await logFile.length() < 2 * 1024 * 1024) return;

    final oldFile = File('${logFile.path}.old');
    if (await oldFile.exists()) await oldFile.delete();
    await logFile.rename(oldFile.path);
  }

  Future<void> _logCoreVersion() async {
    Process? process;
    try {
      process = await Process.start(_corePath, ['-v']);
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      if (exitCode == -1) {
        _log('⚠️ 核心版本检查超时，可能被安全软件拦截');
      } else {
        final output = '${await stdoutFuture}\n${await stderrFuture}'.trim();
        if (exitCode == 0 && output.isNotEmpty) {
          _log('核心版本: ${output.replaceAll(RegExp(r'\s+'), ' ')}');
        } else {
          final reason = _describeWindowsExitCode(exitCode);
          _log(
            '⚠️ 核心版本检查失败，退出码: $exitCode'
            '${reason == null ? "" : "（$reason）"}',
          );
        }
      }
    } catch (e) {
      _log('⚠️ 核心无法执行: $e');
    }
  }

  /// Cleans up cores left behind if the previous app process was terminated.
  Future<void> _terminateOrphanedCores() async {
    if (!Platform.isWindows || _corePath.isEmpty) return;
    final encodedPath = base64Encode(utf8.encode(_corePath));
    final script = '''
\$target = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedPath'))
Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" |
  Where-Object { \$_.ExecutablePath -eq \$target } |
  ForEach-Object {
    Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue
    \$_.ProcessId
  }
''';
    try {
      final result = await _runPowerShell(
        script,
        timeout: const Duration(seconds: 8),
      );
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        _log('已清理遗留的 Mihomo 进程');
      }
    } catch (e) {
      _log('清理遗留核心失败: $e');
    }
  }

  Future<ProcessResult> _runPowerShell(
    String script, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    Process? process;
    try {
      process = await Process.start(_powerShellExecutable(), [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process?.kill(ProcessSignal.sigkill);
          return 124;
        },
      );

      final stdout = await stdoutFuture;
      final stderr = exitCode == 124 ? '电脑性能不足，请重新连接' : await stderrFuture;
      return ProcessResult(process.pid, exitCode, stdout, stderr);
    } catch (_) {
      process?.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  String _powerShellExecutable() {
    if (!Platform.isWindows) return 'powershell';
    final windowsDir =
        Platform.environment['SystemRoot'] ?? Platform.environment['WINDIR'];
    if (windowsDir != null && windowsDir.trim().isNotEmpty) {
      final executable = File(
        '$windowsDir${Platform.pathSeparator}System32'
        '${Platform.pathSeparator}WindowsPowerShell'
        '${Platform.pathSeparator}v1.0'
        '${Platform.pathSeparator}powershell.exe',
      );
      if (executable.existsSync()) return executable.path;
    }
    return 'powershell';
  }

  /// 预下载 MMDB 文件
  Future<void> _ensureMMDB() async {
    final metadbPath = '$_configDir${Platform.pathSeparator}geoip.metadb';
    final mmdbPath = '$_configDir${Platform.pathSeparator}country.mmdb';

    try {
      final m = File(metadbPath);
      if (await m.exists() && await m.length() > 1024 * 1024) {
        _log('✅ MMDB 已存在');
        return;
      }
      final g = File(mmdbPath);
      if (await g.exists() && await g.length() > 1024 * 1024) {
        _log('✅ MMDB 已存在');
        return;
      }
    } catch (_) {}

    // 从内置资源复制（gzip 压缩）
    try {
      await Directory(_configDir).create(recursive: true);
      final assetPath =
          '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}assets${Platform.pathSeparator}geoip.metadb.gz';
      final compressed = await File(assetPath).readAsBytes();
      final bytes = gzip.decode(compressed);
      final file = File(metadbPath);
      final temp = File('$metadbPath.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
      _log(
        '✅ MMDB 已从内置资源解压 (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
    } catch (e) {
      _log('⚠️ MMDB 资源复制失败: $e');
      _log('❌ MMDB 不可用，GEOIP 规则将跳过');
    }
  }

  /// 提取指定段落
  String _extractSection(String yaml, String sectionName) {
    final normalized = yaml.replaceAll('\t', '    ');
    final lines = normalized.split('\n');
    final sectionLines = <String>[];
    bool inSection = false;

    for (final line in lines) {
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        if (line.trim().startsWith('$sectionName:')) {
          inSection = true;
          continue;
        } else if (inSection &&
            line.trim().contains(':') &&
            !line.trim().startsWith('#') &&
            !line.trim().startsWith('-')) {
          break;
        }
      }
      if (inSection) {
        sectionLines.add(line);
      }
    }

    int minIndent = 999;
    for (final line in sectionLines) {
      final t = line.trimLeft();
      if (t.isEmpty) continue;
      final indent = line.length - t.length;
      if (indent < minIndent) minIndent = indent;
    }
    if (minIndent == 999) minIndent = 0;

    final buffer = StringBuffer();
    for (final line in sectionLines) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      final delta = line.length - trimmed.length - minIndent;
      buffer.writeln('${' ' * (delta + 2)}$trimmed');
    }
    return buffer.toString().trimRight();
  }

  /// 提取代理名称列表（loadYaml 解析，失败时 fallback 纯文本）
  List<String> _extractProxyNames(String rawYaml) {
    // 优先用 loadYaml 解析（支持锚点、引用、多行字符串）
    try {
      final yaml = loadYaml(rawYaml);
      if (yaml is Map) {
        final proxies = yaml['proxies'];
        if (proxies is List) {
          return proxies
              .whereType<Map>()
              .map((p) => p['name']?.toString())
              .where((n) => n != null && n.isNotEmpty)
              .cast<String>()
              .toList();
        }
      }
    } catch (_) {}
    // fallback: 纯文本提取（兼容格式不规范的订阅）
    return _extractProxyNamesFromText(rawYaml);
  }

  /// 纯文本方式提取代理名称（fallback）
  List<String> _extractProxyNamesFromText(String rawYaml) {
    final names = <String>[];
    try {
      final proxiesSection = _extractSection(rawYaml, 'proxies');
      for (final line in proxiesSection.split('\n')) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('-')) continue;
        final nameMatch =
            RegExp(r'''name:\s*['"]?([^'"\n,]+)['"]?''').firstMatch(trimmed);
        if (nameMatch != null) names.add(nameMatch.group(1)!.trim());
      }
    } catch (_) {}
    return names;
  }

  /// YAML 单引号字符串转义（过滤控制字符和反斜杠）
  String _quote(String name) {
    final sanitized = name
        .replaceAll('\\', '\\\\')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    return "'${sanitized.replaceAll("'", "''")}'";
  }

  List<String> _buildForceProxyRules(AppSettings settings) {
    return ClashConfigGenerator.buildForceProxyRulesFromSites(
      settings.forceProxySites,
    );
  }

  /// Resolves transient port conflicts without changing the user's saved
  /// preferences. The returned settings must be used to generate the config.
  Future<AppSettings> prepareForStart(AppSettings preferred) async {
    final reserved = <int>{};
    final proxyPort = await _findAvailablePort(
      preferred.proxyPort,
      reserved,
    );
    reserved.add(proxyPort);
    final socksPort = await _findAvailablePort(
      preferred.socksPort,
      reserved,
    );
    reserved.add(socksPort);
    final apiPort = await _findAvailablePort(
      preferred.apiPort,
      reserved,
    );

    final runtime = preferred.copyWith(
      proxyPort: proxyPort,
      socksPort: socksPort,
      apiPort: apiPort,
    );
    _settings = runtime;

    if (proxyPort != preferred.proxyPort ||
        socksPort != preferred.socksPort ||
        apiPort != preferred.apiPort) {
      _log(
        '⚠️ 检测到端口占用，已为本次连接自动调整: '
        '代理 ${preferred.proxyPort}→$proxyPort, '
        'SOCKS ${preferred.socksPort}→$socksPort, '
        'API ${preferred.apiPort}→$apiPort',
      );
    } else {
      _log('端口检查通过: $proxyPort / $socksPort / $apiPort');
    }
    return runtime;
  }

  Future<int> _findAvailablePort(int preferred, Set<int> reserved) async {
    final candidates = <int>[
      preferred,
      for (var offset = 1; offset <= 50; offset++)
        if (preferred + offset <= 65535) preferred + offset,
    ];
    for (final port in candidates) {
      if (reserved.contains(port)) continue;
      if (await _canBindPort(port)) return port;
    }

    while (true) {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      final port = socket.port;
      await socket.close();
      if (!reserved.contains(port)) return port;
    }
  }

  Future<bool> _canBindPort(int port) async {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 生成 Clash 配置
  String generateClashConfig(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) {
    final proxyNames = _extractProxyNames(rawYaml);
    final proxiesText = _extractSection(rawYaml, 'proxies');
    if (proxyNames.isEmpty || proxiesText.isEmpty) {
      throw Exception('订阅中没有可用节点，请先刷新订阅');
    }

    // 检查 MMDB
    final selectedProxyNames = List<String>.from(proxyNames);
    if (preferredNodeName != null &&
        selectedProxyNames.remove(preferredNodeName)) {
      selectedProxyNames.insert(0, preferredNodeName);
    }

    final mmdbExists = (() {
      try {
        final m = File('$_configDir${Platform.pathSeparator}country.mmdb');
        if (m.existsSync() && m.lengthSync() > 1024 * 1024) return true;
        final g = File('$_configDir${Platform.pathSeparator}geoip.metadb');
        if (g.existsSync() && g.lengthSync() > 1024 * 1024) return true;
      } catch (_) {}
      return false;
    })();

    final result = StringBuffer();
    result.writeln('# ===== SSRVPN Windows =====');
    result.writeln('mixed-port: ${settings.proxyPort}');
    result.writeln('socks-port: ${settings.socksPort}');
    result.writeln('allow-lan: false');
    result.writeln('mode: ${settings.proxyMode.name}');
    result.writeln('log-level: info');
    result.writeln("external-controller: '127.0.0.1:${settings.apiPort}'");
    result.writeln('# SSRVPN 当前明确只支持 IPv4 节点与 IPv4 流量');
    result.writeln('ipv6: false');
    if (settings.apiSecret.isNotEmpty) {
      result.writeln('secret: ${_quote(settings.apiSecret)}');
    }

    // TUN 模式配置
    result.writeln();
    result.writeln('tun:');
    result.writeln('  enable: ${settings.enableTun}');
    result.writeln('  stack: ${settings.tunStack}');
    result.writeln('  dns-hijack:');
    result.writeln('    - any:53');
    result.writeln('  auto-route: true');
    result.writeln('  auto-detect-interface: true');
    result.writeln('  route-exclude-address:');
    result.writeln('    - 192.168.0.0/16');
    result.writeln('    - 10.0.0.0/8');
    result.writeln('    - 172.16.0.0/12');
    result.writeln('    - 100.64.0.0/10');

    // DNS
    result.writeln();
    result.writeln('dns:');
    result.writeln('  enable: true');
    result.writeln('  ipv6: false');
    result.writeln('  enhanced-mode: fake-ip');
    result.writeln('  fake-ip-range: 198.18.0.1/16');
    result.writeln('  default-nameserver:');
    result.writeln('    - 223.5.5.5');
    result.writeln('    - 119.29.29.29');
    result.writeln('  nameserver:');
    result.writeln('    - https://dns.alidns.com/dns-query');
    result.writeln('    - https://doh.pub/dns-query');
    result.writeln('    - 223.5.5.5');
    result.writeln('    - 119.29.29.29');
    result.writeln('  fallback:');
    result.writeln('    - https://dns.google/dns-query');
    result.writeln('    - https://cloudflare-dns.com/dns-query');
    result.writeln('    - 8.8.8.8');
    result.writeln('    - 1.1.1.1');
    result.writeln('  fallback-filter:');
    result.writeln('    geoip: true');
    result.writeln('    geoip-code: CN');
    result.writeln('    ipcidr:');
    result.writeln('      - 240.0.0.0/4');
    result.writeln('    domain:');
    result.writeln("      - '*.google.com'");
    result.writeln("      - '*.googlevideo.com'");
    result.writeln("      - '*.youtube.com'");
    result.writeln("      - '*.ytimg.com'");
    result.writeln("      - '*.ggpht.com'");
    result.writeln('  fake-ip-filter:');
    result.writeln("    - '*.lan'");
    result.writeln("    - '*.local'");
    result.writeln("    - '*.localhost'");
    result.writeln("    - '*.googlevideo.com'");
    result.writeln("    - '*.youtube.com'");
    result.writeln("    - '*.ytimg.com'");
    result.writeln("    - '*.ggpht.com'");
    result.writeln("    - '*.googleapis.com'");
    result.writeln("    - 'dns.google'");
    result.writeln("    - 'www.google.com'");

    // Proxies
    result.writeln();
    result.writeln('proxies:');
    result.writeln(proxiesText);

    // Proxy Groups
    result.writeln();
    result.writeln('proxy-groups:');
    result.writeln('  - name: PROXY');
    result.writeln('    type: select');
    result.writeln('    proxies:');
    for (final name in selectedProxyNames) {
      result.writeln("      - ${_quote(name)}");
    }
    result.writeln('  - name: GLOBAL');
    result.writeln('    type: select');
    result.writeln('    proxies:');
    result.writeln("      - 'PROXY'");
    for (final name in selectedProxyNames) {
      result.writeln("      - ${_quote(name)}");
    }
    result.writeln('  - name: 自动选择');
    result.writeln('    type: url-test');
    result.writeln('    proxies:');
    for (final name in proxyNames) {
      result.writeln("      - ${_quote(name)}");
    }
    result.writeln('    url: ${_quote(settings.latencyTestUrl)}');
    result.writeln('    interval: 300');
    result.writeln('  - name: $_geoProxyGroupName');
    result.writeln('    type: select');
    result.writeln('    proxies:');
    for (final name in selectedProxyNames) {
      result.writeln("      - ${_quote(name)}");
    }

    // Rules
    result.writeln();
    result.writeln('rules:');
    for (final rule in _buildForceProxyRules(settings)) {
      result.writeln('  - ${_quote(rule)}');
    }
    for (final host in _geoLookupHosts) {
      result.writeln("  - 'DOMAIN,$host,$_geoProxyGroupName'");
    }
    result.writeln("  - 'DOMAIN-SUFFIX,cn,DIRECT'");
    if (mmdbExists) {
      result.writeln("  - 'GEOIP,CN,DIRECT'");
      result.writeln("  - 'GEOIP,LAN,DIRECT,no-resolve'");
    }
    result.writeln("  - 'MATCH,PROXY'");

    return result.toString();
  }

  /// 写入配置
  Future<void> writeConfig(String configContent) async {
    if (_startupDisabledReason != null) {
      throw StateError(_startupDisabledReason!);
    }
    if (_configPath.isEmpty) {
      throw StateError('Mihomo service is not initialized');
    }
    final file = File(_configPath);
    final temp = File('$_configPath.tmp');
    await temp.writeAsString(configContent);
    await temp.rename(file.path);
  }

  /// 启动核心
  Future<bool> start() {
    final current = _startOperation;
    if (current != null) return current;

    final operation = _startInternal();
    _startOperation = operation;
    operation.then<void>(
      (_) => _clearStartOperation(operation),
      onError: (_, __) => _clearStartOperation(operation),
    );
    return operation;
  }

  Future<bool> _startInternal() async {
    final stopping = _stopOperation;
    if (stopping != null) await stopping;
    _lastStartError = null;
    _lastHealthCheckError = null;

    if (_startupDisabledReason != null) {
      _lastStartError = _startupDisabledReason;
      _log(_startupDisabledReason!);
      return false;
    }
    if (_corePath.isEmpty || _configDir.isEmpty || _configPath.isEmpty) {
      _lastStartError = 'Mihomo service is not initialized';
      _log(_lastStartError!);
      return false;
    }

    if (_isRunning) {
      try {
        if (await _healthCheck()) return true;
      } catch (_) {}
      _isRunning = false;
      _statusTimer?.cancel();
    }

    try {
      final startupWatch = Stopwatch()..start();
      _log('🚀 启动 Mihomo...');

      // 检查核心文件
      if (!File(_corePath).existsSync()) {
        _log('❌ 核心文件不存在: $_corePath');
        _log('请下载 mihomo-windows-amd64 并重命名为 mihomo.exe 放到应用目录');
        _lastStartError = '找不到 mihomo.exe，文件可能未完整解压或被安全软件隔离';
        return false;
      }

      if (!File(_configPath).existsSync()) {
        _log('❌ 配置文件不存在: $_configPath');
        _lastStartError = '找不到生成的 Mihomo 配置文件';
        return false;
      }

      if (_settings.enableTun) {
        final isAdministrator = await _isAdministrator();
        if (isAdministrator == false) {
          _lastStartError = 'TUN 模式需要以管理员身份运行 SSRVPN';
          _log('❌ $_lastStartError');
          return false;
        }
        if (isAdministrator == null) {
          _log('⚠️ 无法确认管理员权限，将继续尝试启动 TUN 模式');
        }
      }

      // 创建 tmp 目录
      final tmpDir = '$_configDir${Platform.pathSeparator}tmp';
      await Directory(tmpDir).create(recursive: true);
      final environment = {'TMPDIR': tmpDir, 'TMP': tmpDir, 'TEMP': tmpDir};

      if (!await _validateConfig(environment)) {
        _lastStartError ??= 'Mihomo 配置校验失败，请打开运行日志查看具体配置错误';
        return false;
      }

      // 启动 mihomo 子进程（所有数据都在便携目录内）
      final processStartWatch = Stopwatch()..start();
      final startedProcess = await Process.start(
        _corePath,
        ['-d', _configDir, '-f', _configPath],
        mode: ProcessStartMode.normal,
        includeParentEnvironment: true,
        environment: environment,
      );
      _log('Mihomo 进程已创建，耗时 ${processStartWatch.elapsedMilliseconds}ms');
      _coreProcess = startedProcess;
      int? startupExitCode;
      final startupOutput = <String>[];

      // 监听子进程输出
      startedProcess.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final message = line.trim();
        if (message.isEmpty) return;
        startupOutput.add(message);
        if (startupOutput.length > 30) startupOutput.removeAt(0);
        _log('[mihomo] $message');
      });
      startedProcess.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final message = line.trim();
        if (message.isEmpty) return;
        startupOutput.add(message);
        if (startupOutput.length > 30) startupOutput.removeAt(0);
        _log('[mihomo stderr] $message');
      });

      // 监听子进程退出
      startedProcess.exitCode.then((code) {
        startupExitCode = code;
        if (!identical(_coreProcess, startedProcess) || _stoppingCore) return;

        _log('❌ Mihomo 进程已退出，退出码: $code');
        if (_isRunning) {
          _isRunning = false;
          _notifyStatusChanged();
          _proxyService.clearSystemProxy();
        }
      });

      // 慢速磁盘或首次启动可能超过 2 秒，轮询等待 API 就绪。
      var healthy = false;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline) && startupExitCode == null) {
        healthy = await _healthCheck();
        if (healthy) break;
        await Future.delayed(const Duration(milliseconds: 250));
      }

      if (healthy) {
        _isRunning = true;
        _consecutiveHealthCheckFailures = 0;
        _log('✅ Mihomo API 就绪，耗时 ${startupWatch.elapsedMilliseconds}ms');

        // 设置系统代理（非 TUN 模式时）
        if (!_settings.enableTun) {
          final proxyWatch = Stopwatch()..start();
          final proxySet = await _proxyService.setSystemProxy(
            '127.0.0.1',
            _settings.proxyPort,
          );
          if (proxySet) {
            _log('✅ 系统代理已设置，耗时 ${proxyWatch.elapsedMilliseconds}ms');
          } else {
            _lastStartError = _proxyService.lastError ?? 'Windows 系统代理设置失败';
            _log('❌ $_lastStartError，连接已取消');
            await _stopInternal();
            return false;
          }
        }

        _notifyStatusChanged();
        _startStatusMonitor();
        return true;
      } else {
        if (startupExitCode != null) {
          final detail = startupOutput.isEmpty ? '' : ': ${startupOutput.last}';
          _lastStartError = 'Mihomo 提前退出（退出码 $startupExitCode）$detail';
          _log('❌ 核心启动失败: $_lastStartError');
        } else {
          final detail = _lastHealthCheckError ?? 'Mihomo API 未在 15 秒内就绪';
          _lastStartError = '电脑性能不足，请重新连接';
          _log(
            '❌ 核心启动后健康检查失败: '
            '$detail',
          );
        }
        await _stopInternal();
        return false;
      }
    } catch (e, stack) {
      _lastStartError = _friendlyStartException(e);
      _log('❌ 启动异常: $e');
      _log('堆栈: $stack');
      await _stopInternal();
      return false;
    }
  }

  Future<bool?> _isAdministrator() async {
    if (!Platform.isWindows) return null;
    const script = r'''
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
''';
    try {
      final result = await _runPowerShell(
        script,
        timeout: const Duration(seconds: 5),
      );
      if (result.exitCode != 0) return null;
      final output = result.stdout.toString().trim().toLowerCase();
      if (output == 'true') return true;
      if (output == 'false') return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  String _friendlyStartException(Object error) {
    final message = error.toString();
    final lower = message.toLowerCase();
    if (lower.contains('access is denied') ||
        lower.contains('permission denied') ||
        lower.contains('拒绝访问')) {
      return '无法执行 Mihomo，文件可能被安全软件拦截或当前目录没有执行权限';
    }
    if (lower.contains('not a valid win32') || lower.contains('不是有效的 win32')) {
      return 'Mihomo 与这台电脑的 Windows 架构不兼容，本版本仅支持 64 位 Windows';
    }
    return '启动 Mihomo 时发生异常: $message';
  }

  String? _describeWindowsExitCode(int exitCode) {
    switch (exitCode) {
      case -1073741819: // 0xC0000005
        return '访问冲突，通常是 CPU 指令集或旧版 Windows 兼容问题，也可能被安全软件注入拦截';
      case -1073741795: // 0xC000001D
        return '非法指令，当前 CPU 不支持此核心使用的指令集';
      case -1073741515: // 0xC0000135
        return '缺少运行库或依赖 DLL';
      case -1073741701: // 0xC000007B
        return '程序或依赖 DLL 的 32/64 位架构不匹配';
      default:
        return null;
    }
  }

  /// 停止核心
  Future<void> stop() {
    final current = _stopOperation;
    if (current != null) return current;

    final operation = _stopAfterStart();
    _stopOperation = operation;
    operation.then<void>(
      (_) => _clearStopOperation(operation),
      onError: (_, __) => _clearStopOperation(operation),
    );
    return operation;
  }

  Future<void> _stopAfterStart() async {
    final starting = _startOperation;
    if (starting != null) await starting;
    await _stopInternal();
  }

  Future<void> _stopInternal() async {
    _statusTimer?.cancel();
    _statusTimer = null;
    _consecutiveHealthCheckFailures = 0;

    if (_coreProcess != null) {
      _stoppingCore = true;
      try {
        _coreProcess!.kill(ProcessSignal.sigterm);
        // 等待进程退出
        await _coreProcess!.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            _coreProcess!.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      } catch (e) {
        _log('停止异常: $e');
      } finally {
        _stoppingCore = false;
      }
      _coreProcess = null;
    }

    // 清除系统代理（在进程停止后执行）
    final proxyCleared = await _proxyService.clearSystemProxy();
    if (!proxyCleared && _proxyService.lastError != null) {
      _log('⚠️ ${_proxyService.lastError}');
    }

    _isRunning = false;
    _notifyStatusChanged();
    _log('核心已停止');
  }

  void _clearStartOperation(Future<bool> operation) {
    if (identical(_startOperation, operation)) {
      _startOperation = null;
    }
  }

  void _clearStopOperation(Future<void> operation) {
    if (identical(_stopOperation, operation)) {
      _stopOperation = null;
    }
  }

  /// 健康检查（使用 HTTP 请求验证 API 可用性）
  Future<bool> _healthCheck() async {
    try {
      final url = Uri.parse('http://127.0.0.1:${_settings.apiPort}/version');
      final response = await _apiClient
          .get(url, headers: _apiHeaders())
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        _lastHealthCheckError = null;
        return true;
      }
      _lastHealthCheckError =
          'API 返回 HTTP ${response.statusCode}，端口 ${_settings.apiPort}';
      return false;
    } catch (e) {
      _lastHealthCheckError = '无法连接 127.0.0.1:${_settings.apiPort} ($e)';
      return false;
    }
  }

  Future<String?> verifyUserConnectivity() async {
    final client = IOClient(
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..findProxy = (_) => 'PROXY 127.0.0.1:${_settings.proxyPort}; DIRECT',
    );
    try {
      final response = await client
          .get(Uri.parse('http://www.gstatic.com/generate_204'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 204 || response.statusCode == 200) {
        return null;
      }
      return '已连接，但网络验证返回 HTTP ${response.statusCode}，请尝试切换节点';
    } catch (_) {
      return '已连接，但网络验证失败，请尝试切换节点或刷新订阅';
    } finally {
      client.close();
    }
  }

  Future<bool> _validateConfig(Map<String, String> environment) async {
    _log('正在校验 Mihomo 配置...');
    final watch = Stopwatch()..start();
    Process? process;
    try {
      process = await Process.start(
        _corePath,
        ['-t', '-d', _configDir, '-f', _configPath],
        includeParentEnvironment: true,
        environment: environment,
      );
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 40),
        onTimeout: () {
          process?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      final stdout = (await stdoutFuture).trim();
      final stderr = (await stderrFuture).trim();
      if (stdout.isNotEmpty) _log('[配置校验] $stdout');
      if (stderr.isNotEmpty) _log('[配置校验 stderr] $stderr');
      if (exitCode == 0) {
        _log('✅ Mihomo 配置校验通过，耗时 ${watch.elapsedMilliseconds}ms');
        return true;
      }
      if (exitCode == -1) {
        _lastStartError = '电脑性能不足，请重新连接';
        _log('❌ $_lastStartError');
        return false;
      }
      final reason = _describeWindowsExitCode(exitCode);
      final detail = stderr.isNotEmpty ? stderr : stdout;
      if (reason != null) {
        _lastStartError = 'Mihomo 无法在此电脑运行: $reason';
      } else if (detail.isNotEmpty) {
        _lastStartError = 'Mihomo 配置校验失败: $detail';
      }
      _log(
        '❌ Mihomo 配置校验失败，退出码: $exitCode'
        '${reason == null ? "" : "（$reason）"}',
      );
      return false;
    } catch (e) {
      process?.kill(ProcessSignal.sigkill);
      _log('❌ 无法执行 Mihomo 配置校验: $e');
      return false;
    }
  }

  String _apiUrl(String path) {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return 'http://127.0.0.1:${_settings.apiPort}/$cleanPath';
  }

  Map<String, String> _apiHeaders([Map<String, String>? extra]) {
    return {
      if (_settings.apiSecret.isNotEmpty)
        'Authorization': 'Bearer ${_settings.apiSecret}',
      ...?extra,
    };
  }

  /// 测试延迟 (TCP 连接)
  Future<String?> detectExitCountryForProxy(
    String nodeName, {
    Duration timeout = const Duration(seconds: 7),
  }) async {
    if (!_isRunning || nodeName.trim().isEmpty) return null;

    final groupName =
        _settings.proxyMode == ProxyMode.global ? 'GLOBAL' : _geoProxyGroupName;
    final previousSelection = groupName == 'GLOBAL'
        ? await _currentProxyGroupSelection(groupName)
        : null;

    final switched = await _switchProxyGroup(groupName, nodeName);
    if (!switched) return null;

    try {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return await _queryExitCountry(timeout: timeout);
    } finally {
      if (previousSelection != null &&
          previousSelection.isNotEmpty &&
          previousSelection != nodeName) {
        await _switchProxyGroup(groupName, previousSelection);
      }
    }
  }

  Future<String?> _currentProxyGroupSelection(String groupName) async {
    try {
      final response = await _apiClient
          .get(
            Uri.parse(_apiUrl('/proxies/${Uri.encodeComponent(groupName)}')),
            headers: _apiHeaders(),
          )
          .timeout(const Duration(seconds: 3));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded['now']?.toString();
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _queryExitCountry({required Duration timeout}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..findProxy = (_) => 'PROXY 127.0.0.1:${_settings.proxyPort}; DIRECT';
    try {
      for (final uri in const [
        'https://api.country.is/',
        'https://ipinfo.io/country',
        'https://ifconfig.co/country-iso',
      ]) {
        final country = await _queryExitCountryFrom(
          client,
          Uri.parse(uri),
          timeout,
        );
        if (country != null) return country;
      }
    } finally {
      client.close(force: true);
    }
    return null;
  }

  Future<String?> _queryExitCountryFrom(
    HttpClient client,
    Uri uri,
    Duration timeout,
  ) async {
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json,text/*');
      request.headers.set(HttpHeaders.userAgentHeader, 'SSRVPN/2.0');
      final response = await request.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 500) {
        return null;
      }
      final body = await utf8.decodeStream(response).timeout(timeout);
      return _parseCountryCode(body);
    } catch (_) {
      return null;
    }
  }

  String? _parseCountryCode(String body) {
    final text = body.trim();
    if (text.isEmpty) return null;
    final plain = _normalizeCountryCode(text);
    if (plain != null) return plain;

    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        for (final key in const ['country', 'countryCode', 'country_code']) {
          final value = decoded[key]?.toString();
          final code = _normalizeCountryCode(value);
          if (code != null) return code;
        }
      }
    } catch (_) {}
    return null;
  }

  String? _normalizeCountryCode(String? value) {
    final code = value?.trim().toUpperCase() ?? '';
    if (code.length != 2 || !RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
      return null;
    }
    if (code == 'UK') return 'GB';
    if (code == 'EL') return 'GR';
    return code;
  }

  Future<int> testLatency(
    String server,
    int port, {
    int timeoutMs = 5000,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        server,
        port,
        timeout: Duration(milliseconds: timeoutMs),
      );
      socket.destroy();
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return -1;
    }
  }

  /// 批量测速
  Future<void> testAllLatencies(
    List<ProxyNode> nodes,
    void Function(String name, int latency) onResult, {
    int concurrency = 10,
    int timeoutMs = 5000,
  }) async {
    final random = Random();
    for (var i = 0; i < nodes.length; i += concurrency) {
      if (!_isRunning) break; // 核心停止后终止测速
      final batch = nodes.skip(i).take(concurrency).toList();
      final results = await Future.wait(
        batch.map((n) => testLatency(n.server, n.port, timeoutMs: timeoutMs)),
      );
      for (var j = 0; j < batch.length; j++) {
        final latency = PrivateNodeLatencyPolicy.displayLatencyForNode(
          batch[j].name,
          results[j],
          random: random,
        );
        onResult(batch[j].name, latency);
      }
    }
  }

  /// 切换代理节点
  Future<bool> switchProxy(String groupName, String nodeName) async {
    final ok = await _switchProxyGroup(groupName, nodeName);
    if (ok) {
      await _closeConnections();
    }
    return ok;
  }

  Future<bool> switchSelectedProxy(String nodeName) async {
    final proxyOk = await _switchProxyGroup('PROXY', nodeName);
    var globalOk = true;
    if (_settings.proxyMode == ProxyMode.global) {
      globalOk = await _switchProxyGroup('GLOBAL', 'PROXY');
      if (!globalOk) {
        globalOk = await _switchProxyGroup('GLOBAL', nodeName);
      }
    }
    if (proxyOk && globalOk) {
      await _closeConnections();
    }
    return proxyOk && globalOk;
  }

  Future<bool> _switchProxyGroup(String groupName, String nodeName) async {
    try {
      final url = _apiUrl('/proxies/${Uri.encodeComponent(groupName)}');
      _log('切换代理: group=$groupName, node=$nodeName');
      _log('API URL: $url');

      final response = await _apiClient
          .put(
            Uri.parse(url),
            headers: _apiHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'name': nodeName}),
          )
          .timeout(const Duration(seconds: 5));

      _log('API 响应: ${response.statusCode} ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 204) {
        _log('✅ 代理切换成功: $nodeName');
        return true;
      }
      _log('❌ 代理切换失败: HTTP ${response.statusCode}');
      return false;
    } catch (e) {
      _log('❌ 切换代理异常: $e');
      return false;
    }
  }

  Future<void> _closeConnections() async {
    try {
      await _apiClient
          .delete(
            Uri.parse(_apiUrl('/connections')),
            headers: _apiHeaders(),
          )
          .timeout(const Duration(seconds: 3));
      _log('✅ 已断开旧连接');
    } catch (e) {
      _log('断开旧连接失败 (可忽略): $e');
    }
  }

  bool _healthCheckInProgress = false;

  void _startStatusMonitor() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_isRunning || _healthCheckInProgress) return;
      _healthCheckInProgress = true;
      try {
        final healthy = await _healthCheck();
        if (healthy) {
          _consecutiveHealthCheckFailures = 0;
        } else if (_isRunning) {
          _consecutiveHealthCheckFailures++;
          _log(
            '核心健康检查失败 ($_consecutiveHealthCheckFailures/'
            '$_maxConsecutiveHealthCheckFailures): $_lastHealthCheckError',
          );
          if (_consecutiveHealthCheckFailures >=
              _maxConsecutiveHealthCheckFailures) {
            _isRunning = false;
            _log('核心连接丢失');
            _notifyStatusChanged();
            await stop();
          }
        }
      } finally {
        _healthCheckInProgress = false;
      }
    });
  }

  static const bool _kReleaseMode = bool.fromEnvironment('dart.vm.product');

  void _log(String message) {
    final sanitized = LogRedactor.sanitize(message);
    _logBuffer = '$sanitized\n$_logBuffer';
    if (_logBuffer.length > 10000) _logBuffer = _logBuffer.substring(0, 10000);
    // Release模式下跳过文件日志写入，减少I/O开销
    if (_kReleaseMode) {
      onLog?.call(sanitized);
      return;
    }
    final logFile = _logFile;
    if (logFile != null) {
      final line = '[${DateTime.now().toIso8601String()}] $sanitized\r\n';
      _pendingLogWrite = _pendingLogWrite
          .then(
            (_) => logFile.writeAsString(
              line,
              mode: FileMode.append,
              flush: true,
            ),
          )
          .then<void>((_) {})
          .catchError((Object _, StackTrace __) {});
    }
    onLog?.call(sanitized);
    debugPrint('[Clash] $sanitized');
  }

  void addStatusListener(VoidCallback listener) {
    _statusListeners.add(listener);
  }

  void removeStatusListener(VoidCallback listener) {
    _statusListeners.remove(listener);
  }

  void _notifyStatusChanged() {
    for (final listener in List<VoidCallback>.from(_statusListeners)) {
      listener();
    }
  }

  void setCorePath(String path) => _corePath = path;
  bool get coreExists => File(_corePath).existsSync();
  String get corePath => _corePath;
}
