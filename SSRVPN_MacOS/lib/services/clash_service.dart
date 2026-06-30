import 'dart:async';
import 'package:ssrvpn_shared/models/app_settings.dart' show ProxyMode;
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/models/proxy_group.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/utils/log_redactor.dart';
import 'package:ssrvpn_shared/utils/private_node_latency_policy.dart';
import '../models/app_settings.dart';
import 'system_proxy_service.dart';

/// Clash Meta 核心管理服务
class ClashService {
  static const _chmodPath = '/bin/chmod';
  static const _chownPath = '/usr/sbin/chown';
  static const _filePath = '/usr/bin/file';
  static const _osascriptPath = '/usr/bin/osascript';
  static const _pkillPath = '/usr/bin/pkill';
  static const _statPath = '/usr/bin/stat';

  Process? _clashProcess;
  Timer? _statusTimer;
  Future<bool>? _startOperation;
  Future<void>? _stopOperation;
  bool _isRunning = false;
  bool _stoppingCore = false;
  bool _healthCheckInProgress = false;
  String? _lastHealthCheckError;
  String? _lastStartError;
  String? _startupDisabledReason;
  int _consecutiveHealthCheckFailures = 0;
  static const int _maxConsecutiveHealthCheckFailures = 3;
  final String _coreName = 'AtlasCore';

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

  // 回调
  VoidCallback? onStatusChanged;

  /// 进程异常退出时的回调（用于清除系统代理等清理操作）
  VoidCallback? onProcessExit;
  void Function(String message)? onLog;
  final Set<VoidCallback> _statusListeners = {};

  bool get isRunning => _isRunning;
  String? get lastStartError => _lastStartError;
  String? get startupDisabledReason => _startupDisabledReason;
  bool get isStartupDisabled => _startupDisabledReason != null;
  String get recentLogs => _logBuffer;
  String get logPath => _logFile?.path ?? '';
  int get runtimeProxyPort => _settings.proxyPort;
  int get runtimeSocksPort => _settings.socksPort;
  int get runtimeApiPort => _settings.apiPort;

  static HttpClient _createDirectHttpClient() {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 3);
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

  /// 初始化服务，设置路径
  ///
  /// macOS：数据保存在 ~/Library/Application Support/SSRVPN，
  /// 核心与 geoip 数据库随应用打包，首次运行时释放到该目录。
  Future<void> init(
    AppSettings settings, {
    String? dataDir,
    String? storageNotice,
    bool skipCoreProbes = false,
  }) async {
    _settings = settings;
    _startupDisabledReason = null;

    if (dataDir != null && dataDir.isNotEmpty) {
      _configDir = dataDir;
    } else {
      final supportDir = await getApplicationSupportDirectory();
      _configDir = '${supportDir.path}${Platform.pathSeparator}SSRVPN';
    }
    _configPath = '$_configDir${Platform.pathSeparator}config.yaml';
    await Directory(_configDir).create(recursive: true);
    _logFile = File('$_configDir${Platform.pathSeparator}ssrvpn.log');
    await _rotateLogFile();
    await _proxyService.initialize(_configDir);

    _corePath = '$_configDir${Platform.pathSeparator}$_coreName';

    // 资源以 gzip 压缩形式打包以减小安装体积，首次运行时解压释放
    await _installAsset('assets/AtlasCore.gz', _corePath, executable: true);
    await _installAsset(
      'assets/geoip.metadb.gz',
      '$_configDir${Platform.pathSeparator}geoip.metadb',
    );
    if (!skipCoreProbes) {
      await _terminateOrphanedCores();
    }

    _log('系统: ${Platform.operatingSystemVersion}');
    _log('程序路径: ${Platform.resolvedExecutable}');
    _log('配置目录: $_configDir');
    _log('核心路径: $_corePath');
    _log('诊断日志: ${_logFile!.path}');
    if (storageNotice != null && storageNotice.isNotEmpty) {
      _log(storageNotice);
    }
    if (_proxyService.lastError != null) {
      _log(_proxyService.lastError!);
    }
    if (!skipCoreProbes) {
      await _logCoreVersion();
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

  /// 从应用包内释放资源文件到目标路径（仅在不存在或资源更新时写入）
  /// .gz 资源自动解压
  Future<void> _installAsset(
    String assetKey,
    String destPath, {
    bool executable = false,
  }) async {
    try {
      final dest = File(destPath);
      final marker = File('$destPath.rev');
      final data = await rootBundle.load(assetKey);
      final compressedBytes = data.buffer.asUint8List();
      final assetRevision = crypto.sha256.convert(compressedBytes).toString();

      // marker 记录源资源 SHA256；一致则跳过昂贵的 gzip 解压
      if (await dest.exists() &&
          await marker.exists() &&
          (await marker.readAsString()) == assetRevision) {
        if (executable) await _chmodExec(destPath);
        return;
      }

      var bytes = compressedBytes;
      if (assetKey.endsWith('.gz')) {
        final compressed = bytes;
        // 核心二进制解压有几十 MB，放后台 isolate 避免卡 UI
        bytes = Uint8List.fromList(
          await Isolate.run(() => gzip.decode(compressed)),
        );
      }
      final existingMatches = await _fileContentMatches(dest, bytes);
      // 核心被授予 setuid root 后可能无法覆盖写；内容未变时跳过即可。
      if (!existingMatches) {
        await _writeBytesAtomically(dest, bytes);
        _log('已释放资源: $assetKey -> $destPath');
      }
      await _writeStringAtomically(marker, assetRevision);
      if (executable) await _chmodExec(destPath);
    } catch (e) {
      _log('释放资源失败 $assetKey: $e');
    }
  }

  Future<void> _chmodExec(String path) async {
    try {
      // 注意：核心被授予 setuid root 后此处会因权限失败，静默忽略即可
      await _runProcess(_chmodPath, ['755', path],
          timeout: const Duration(seconds: 5));
    } catch (_) {}
  }

  /// 从原始YAML提取指定顶层段的原始内容
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

    // 计算最小缩进（排除空行）
    int minIndent = 999;
    for (final line in sectionLines) {
      final t = line.trimLeft();
      if (t.isEmpty) continue;
      final indent = line.length - t.length;
      if (indent < minIndent) minIndent = indent;
    }
    if (minIndent == 999) minIndent = 0;

    // 重建：保留相对缩进
    final buffer = StringBuffer();
    for (final line in sectionLines) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      final delta = line.length - trimmed.length - minIndent;
      buffer.writeln('${' ' * (delta + 2)}$trimmed');
    }
    return buffer.toString().trimRight();
  }

  /// 从订阅YAML中只提取代理节点列表（名称列表，用于proxy-groups）
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

  String? _lastConfigOutput;
  String? _lastConfigInput;

  /// 生成Clash配置（订阅只取节点，规则和分流完全内置）
  String generateClashConfig(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) {
    // 简单缓存：输入内容和设置相同时直接返回缓存结果
    final inputHash =
        '${rawYaml.hashCode}_${settings.hashCode}_$preferredNodeName';
    if (_lastConfigInput == inputHash && _lastConfigOutput != null) {
      return _lastConfigOutput!;
    }

    // 只从订阅提取代理节点
    final proxyNames = _extractProxyNames(rawYaml);
    final proxiesText = _extractSection(rawYaml, 'proxies');
    if (proxyNames.isEmpty || proxiesText.isEmpty) {
      throw Exception('订阅中没有可用节点，请先刷新订阅');
    }

    final result = StringBuffer();
    result.writeln('# ===== SSRVPN 配置（规则内置，订阅仅加载节点） =====');
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

    // TUN 模式（虚拟网卡接管全部流量，核心需要 root 权限）
    if (settings.enableTun) {
      result.writeln();
      result.writeln('tun:');
      result.writeln('  enable: true');
      result.writeln('  stack: ${settings.tunStack}');
      result.writeln('  auto-route: true');
      result.writeln('  auto-detect-interface: true');
      result.writeln('  route-exclude-address:');
      result.writeln('    - 192.168.0.0/16');
      result.writeln('    - 10.0.0.0/8');
      result.writeln('    - 172.16.0.0/12');
      result.writeln('    - 100.64.0.0/10');
      result.writeln('  dns-hijack:');
      result.writeln('    - any:53');
      result.writeln('  route-address-set:');
      result.writeln('    - geoip-cn');
      result.writeln('    - geosite-cn');
    }

    // DNS配置
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

    // 代理节点
    result.writeln();
    result.writeln('proxies:');
    result.writeln(proxiesText);

    // 内置代理组
    result.writeln();
    result.writeln('proxy-groups:');
    result.writeln('  - name: PROXY');
    result.writeln('    type: select');
    result.writeln('    proxies:');
    final preferredNode = preferredNodeName ?? settings.lastSelectedNodeName;
    final proxySelectionOrder = preferredNode != null &&
            proxyNames.contains(preferredNode)
        ? [preferredNode, ...proxyNames.where((name) => name != preferredNode)]
        : proxyNames;
    for (final name in proxySelectionOrder) {
      result.writeln("      - ${_quote(name)}");
    }
    result.writeln('  - name: GLOBAL');
    result.writeln('    type: select');
    result.writeln('    proxies:');
    result.writeln("      - 'PROXY'");
    for (final name in proxySelectionOrder) {
      result.writeln("      - ${_quote(name)}");
    }
    result.writeln('  - name: 自动选择');
    result.writeln('    type: url-test');
    result.writeln('    proxies:');
    for (final name in proxyNames) {
      result.writeln("      - ${_quote(name)}");
    }
    result.writeln("    url: 'http://www.gstatic.com/generate_204'");
    result.writeln('    interval: 300');
    result.writeln('  - name: 故障转移');
    result.writeln('    type: fallback');
    result.writeln('    proxies:');
    for (final name in proxyNames) {
      result.writeln("      - ${_quote(name)}");
    }
    result.writeln("    url: 'http://www.gstatic.com/generate_204'");
    result.writeln('    interval: 300');

    // 内置分流规则
    result.writeln();
    result.writeln('rules:');
    for (final rule in _buildForceProxyRules(settings)) {
      result.writeln('  - ${_quote(rule)}');
    }
    result.writeln(_builtinRules());

    final output = result.toString();
    _lastConfigOutput = output;
    _lastConfigInput = inputHash;
    return output;
  }

  /// 核心是否已具备 root 权限（owner=root 且 setuid 位）
  Future<bool> _coreHasRootPrivilege() async {
    try {
      final result = await _runProcess(
        _statPath,
        ['-f', '%Su %Mp%Lp', _corePath],
        timeout: const Duration(seconds: 5),
      );
      if (result.exitCode != 0) return false;
      final parts = (result.stdout as String).trim().split(' ');
      if (parts.length != 2) return false;
      final isRoot = parts[0] == 'root';
      final hasSetuid = parts[1].length >= 4 && parts[1][0] == '4';
      return isRoot && hasSetuid;
    } catch (_) {
      return false;
    }
  }

  /// 弹出系统授权窗口，为核心设置 setuid root（仅首次开启 TUN 时需要）
  Future<bool> _grantRootPrivilege() async {
    try {
      final escaped = _corePath.replaceAll('"', '\\"');
      final script =
          'do shell script "$_chownPath root:wheel \\"$escaped\\" && $_chmodPath u+s \\"$escaped\\"" '
          'with administrator privileges with prompt "SSRVPN 需要管理员权限以启用 TUN 模式"';
      final result = await _runProcess(
        _osascriptPath,
        ['-e', script],
        timeout: const Duration(minutes: 2),
      );
      if (result.exitCode == 124) {
        _lastStartError = 'TUN 授权超时，请重新连接并在系统弹窗中完成管理员授权';
        return false;
      }
      if (result.exitCode != 0) {
        final stderr = result.stderr.toString().trim();
        _lastStartError =
            stderr.isEmpty ? 'TUN 模式需要管理员授权，已取消' : 'TUN 授权失败: $stderr';
      }
      return result.exitCode == 0;
    } catch (_) {
      _lastStartError = '无法弹出 TUN 管理员授权窗口';
      return false;
    }
  }

  /// YAML 单引号字符串转义（' -> ''）
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

  /// Resolves transient port conflicts without changing saved preferences.
  Future<AppSettings> prepareForStart(AppSettings preferred) async {
    final reserved = <int>{};
    final proxyPort = await _findAvailablePort(preferred.proxyPort, reserved);
    reserved.add(proxyPort);
    final socksPort = await _findAvailablePort(preferred.socksPort, reserved);
    reserved.add(socksPort);
    final apiPort = await _findAvailablePort(preferred.apiPort, reserved);

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
        '检测到端口占用，已为本次连接自动调整: '
        '代理 ${preferred.proxyPort}->$proxyPort, '
        'SOCKS ${preferred.socksPort}->$socksPort, '
        'API ${preferred.apiPort}->$apiPort',
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

  /// 内置分流规则（国内直连 + GEOIP 分流）
  String _builtinRules() {
    return "  - 'DOMAIN-SUFFIX,cn,DIRECT'\n"
        "  - 'GEOIP,CN,DIRECT'\n"
        "  - 'GEOIP,LAN,DIRECT,no-resolve'\n"
        "  - 'MATCH,PROXY'\n";
  }

  /// 将配置写入文件
  Future<void> writeConfig(String configContent) async {
    final file = File(_configPath);
    await _writeStringAtomically(file, configContent);
  }

  /// 启动 Clash 核心
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
      _clashProcess = null;
      _statusTimer?.cancel();
    }

    try {
      final startupWatch = Stopwatch()..start();
      _log('启动 Mihomo 核心...');
      _log('核心路径: $_corePath');
      _log('配置目录: $_configDir');

      if (!File(_corePath).existsSync()) {
        _lastStartError = '找不到核心文件，应用资源可能未完整安装';
        _log('错误: 找不到核心文件 $_corePath');
        return false;
      }
      if (!File(_configPath).existsSync()) {
        _lastStartError = '找不到生成的 Mihomo 配置文件';
        _log('错误: 找不到配置文件 $_configPath');
        return false;
      }

      if (_settings.enableTun && !await _coreHasRootPrivilege()) {
        final granted = await _grantRootPrivilege();
        if (!granted) {
          _lastStartError ??= 'TUN 模式需要管理员授权，已取消';
          _log(_lastStartError!);
          return false;
        }
      }

      final tmpDir = '$_configDir${Platform.pathSeparator}tmp';
      await Directory(tmpDir).create(recursive: true);
      final environment = {'TMPDIR': tmpDir, 'TMP': tmpDir, 'TEMP': tmpDir};

      if (!await _validateConfig(environment)) {
        _lastStartError ??= 'Mihomo 配置校验失败，请打开运行日志查看具体错误';
        return false;
      }

      final processStartWatch = Stopwatch()..start();
      final startedProcess = await Process.start(
        _corePath,
        ['-d', _configDir, '-f', _configPath],
        workingDirectory: _configDir,
        mode: ProcessStartMode.normal,
        includeParentEnvironment: true,
        environment: environment,
      );
      _log('Mihomo 进程已创建，耗时 ${processStartWatch.elapsedMilliseconds}ms');
      _clashProcess = startedProcess;
      int? startupExitCode;
      final startupOutput = <String>[];

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

      startedProcess.exitCode.then((code) {
        startupExitCode = code;
        if (!identical(_clashProcess, startedProcess) || _stoppingCore) return;

        _log('Mihomo 进程已退出，退出码: $code');
        if (_isRunning) {
          _isRunning = false;
          _notifyStatusChanged();
        }
        // 通知外部进程异常退出（用于清除系统代理等）
        _proxyService.clearSystemProxy();
        onProcessExit?.call();
      });

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
        _log('Mihomo API 就绪，耗时 ${startupWatch.elapsedMilliseconds}ms');

        if (!_settings.enableTun) {
          final proxySet = await _proxyService.setSystemProxy(
            '127.0.0.1',
            _settings.proxyPort,
          );
          if (!proxySet) {
            _lastStartError = _proxyService.lastError ?? 'macOS 系统代理设置失败';
            _log(_lastStartError!);
            await _stopInternal();
            return false;
          }
          _log('macOS 系统代理已设置');
        }

        _notifyStatusChanged();
        _startStatusMonitor();
        return true;
      }

      if (startupExitCode != null) {
        final detail = startupOutput.isEmpty ? '' : ': ${startupOutput.last}';
        _lastStartError = 'Mihomo 提前退出（退出码 $startupExitCode）$detail';
      } else {
        _lastStartError = '电脑性能不足或核心启动过慢，请重新连接';
      }
      _log('核心启动失败: ${_lastHealthCheckError ?? _lastStartError}');
      await _stopInternal();
      return false;
    } catch (e, stack) {
      _lastStartError = _friendlyStartException(e);
      _log('启动核心异常: $e');
      _log('堆栈: $stack');
      await _stopInternal();
      return false;
    }
  }

  /// 停止 Clash 核心
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

    final process = _clashProcess;
    if (process != null) {
      _stoppingCore = true;
      try {
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      } catch (e) {
        _log('停止核心异常: $e');
      } finally {
        _stoppingCore = false;
      }
      _clashProcess = null;
    }

    final proxyCleared = await _proxyService.clearSystemProxy();
    if (!proxyCleared && _proxyService.lastError != null) {
      _log(_proxyService.lastError!);
    }

    _isRunning = false;
    _notifyStatusChanged();
    _log('Mihomo 核心已停止');
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

  /// 健康检查（使用 HTTP 请求验证 API 可用性）。
  Future<bool> _healthCheck() async {
    try {
      final response = await _apiClient
          .get(Uri.parse(_apiUrl('/version')), headers: _apiHeaders())
          .timeout(const Duration(seconds: 2));
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

  Future<String?> resolveCurrentExitCountryCode() async {
    final client = IOClient(
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..findProxy = (_) => 'PROXY 127.0.0.1:${_settings.proxyPort}; DIRECT',
    );
    const endpoints = [
      'http://ip-api.com/json/?fields=status,countryCode,query',
      'https://ipinfo.io/json',
    ];

    try {
      for (final endpoint in endpoints) {
        try {
          final response = await client
              .get(Uri.parse(endpoint))
              .timeout(const Duration(seconds: 8));
          if (response.statusCode != 200) continue;

          final decoded = jsonDecode(response.body);
          if (decoded is! Map<String, dynamic>) continue;
          final country = decoded['countryCode']?.toString() ??
              decoded['country']?.toString();
          final normalized = _normalizeCountryCode(country);
          if (normalized != null) return normalized;
        } catch (_) {}
      }
      return null;
    } finally {
      client.close();
    }
  }

  String? _normalizeCountryCode(String? value) {
    final code = value?.trim().toUpperCase() ?? '';
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(code)) return null;
    if (code == 'UK') return 'GB';
    if (code == 'EL') return 'GR';
    return code;
  }

  Future<bool> _validateConfig(Map<String, String> environment) async {
    _log('正在校验 Mihomo 配置...');
    final watch = Stopwatch()..start();
    try {
      final result = await _runProcess(
        _corePath,
        ['-t', '-d', _configDir, '-f', _configPath],
        workingDirectory: _configDir,
        includeParentEnvironment: true,
        environment: environment,
        timeout: const Duration(seconds: 40),
      );
      final stdout = result.stdout.toString().trim();
      final stderr = result.stderr.toString().trim();
      if (stdout.isNotEmpty) _log('[配置校验] $stdout');
      if (stderr.isNotEmpty) _log('[配置校验 stderr] $stderr');
      if (result.exitCode == 0) {
        _log('Mihomo 配置校验通过，耗时 ${watch.elapsedMilliseconds}ms');
        return true;
      }
      if (result.exitCode == 124) {
        _lastStartError = '电脑性能不足或配置校验超时，请重新连接';
      } else if (stderr.isNotEmpty || stdout.isNotEmpty) {
        _lastStartError = 'Mihomo 配置校验失败: '
            '${stderr.isNotEmpty ? stderr : stdout}';
      }
      _log('Mihomo 配置校验失败，退出码: ${result.exitCode}');
      return false;
    } catch (e) {
      _lastStartError = _friendlyStartException(e);
      _log('无法执行 Mihomo 配置校验: $e');
      return false;
    }
  }

  Future<void> _logCoreVersion() async {
    if (!await File(_corePath).exists()) {
      _log('核心文件不存在: $_corePath');
      return;
    }
    try {
      final stat = await File(_corePath).stat();
      _log('核心文件大小: ${(stat.size / 1024 / 1024).toStringAsFixed(1)} MB');
    } catch (_) {}

    try {
      final fileInfo = await _runProcess(
        _filePath,
        [_corePath],
        timeout: const Duration(seconds: 5),
      );
      if (fileInfo.exitCode == 0 &&
          fileInfo.stdout.toString().trim().isNotEmpty) {
        _log('核心架构: ${fileInfo.stdout.toString().trim()}');
      }
    } catch (_) {}

    try {
      final result = await _runProcess(
        _corePath,
        ['-v'],
        workingDirectory: _configDir,
        timeout: const Duration(seconds: 5),
      );
      final output = '${result.stdout}\n${result.stderr}'.trim();
      if (result.exitCode == 0 && output.isNotEmpty) {
        _log('核心版本: ${output.replaceAll(RegExp(r'\s+'), ' ')}');
      } else if (result.exitCode == 124) {
        _log('核心版本检查超时');
      } else {
        _log('核心版本检查失败，退出码: ${result.exitCode}');
      }
    } catch (e) {
      _log('核心无法执行: $e');
    }
  }

  Future<void> _terminateOrphanedCores() async {
    if (_corePath.isEmpty || !Platform.isMacOS) return;
    try {
      final result = await _runProcess(
        _pkillPath,
        ['-f', _corePath],
        timeout: const Duration(seconds: 5),
      );
      if (result.exitCode == 0) {
        _log('已清理遗留的 Mihomo 进程');
      }
    } catch (e) {
      _log('清理遗留核心失败: $e');
    }
  }

  String _friendlyStartException(Object error) {
    final message = error.toString();
    final lower = message.toLowerCase();
    if (lower.contains('permission denied') ||
        lower.contains('operation not permitted') ||
        lower.contains('权限') ||
        lower.contains('拒绝')) {
      return '无法执行 Mihomo，可能缺少权限或 TUN 授权未完成';
    }
    if (lower.contains('bad cpu type') ||
        lower.contains('exec format') ||
        lower.contains('unsupported architecture')) {
      return 'Mihomo 与当前 Mac 架构不兼容';
    }
    return '启动 Mihomo 时发生异常: $message';
  }

  /// API基础URL
  String _apiUrl(String path) {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return 'http://127.0.0.1:${_settings.apiPort}/$cleanPath';
  }

  /// API请求头（external-controller 的认证方式是 Authorization: Bearer）
  Map<String, String> _apiHeaders({bool json = false}) {
    return {
      if (_settings.apiSecret.isNotEmpty)
        'Authorization': 'Bearer ${_settings.apiSecret}',
      if (json) 'Content-Type': 'application/json',
    };
  }

  /// 获取代理节点列表
  Future<List<ProxyGroup>> getProxies() async {
    try {
      final response = await _apiClient
          .get(Uri.parse(_apiUrl('/proxies')), headers: _apiHeaders())
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final proxies = data['proxies'] as Map<String, dynamic>? ?? {};

        final groups = <ProxyGroup>[];
        for (final entry in proxies.entries) {
          final proxyData = entry.value as Map<String, dynamic>;
          final type = proxyData['type'] as String? ?? '';

          if (type == 'Selector' ||
              type == 'URLTest' ||
              type == 'Fallback' ||
              type == 'LoadBalance') {
            // 这是一个代理组
            final allNames = (proxyData['all'] as List?)?.cast<String>() ?? [];
            final nodes = <ProxyNode>[];
            for (final name in allNames) {
              // 跳过其他组名
              if (proxies.containsKey(name) &&
                  (proxies[name] as Map<String, dynamic>)['type'] !=
                      'Selector') {
                final nodeData = proxies[name] as Map<String, dynamic>;
                nodes.add(
                  ProxyNode(
                    name: name,
                    type: nodeData['type'] as String? ?? 'unknown',
                    server: nodeData['server'] as String? ?? '',
                    port: nodeData['port'] as int? ?? 0,
                    group: entry.key,
                  ),
                );
              }
            }

            groups.add(
              ProxyGroup(
                name: entry.key,
                type: type.toLowerCase(),
                nodes: nodes,
                selectedNode: proxyData['now'] as String?,
              ),
            );
          }
        }

        return groups;
      }
    } catch (e) {
      _log('获取代理列表失败: $e');
    }
    return [];
  }

  /// 测试节点延迟（直连TCP，与Android一致）
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

  Future<void> testAllLatencies(
    List<ProxyNode> nodes,
    void Function(String name, int latency) onResult, {
    int concurrency = 10,
    int timeoutMs = 5000,
  }) async {
    final random = Random();
    for (var i = 0; i < nodes.length; i += concurrency) {
      if (!_isRunning) break;
      final batch = nodes.skip(i).take(concurrency).toList();
      final results = await Future.wait(
        batch.map((node) =>
            testLatency(node.server, node.port, timeoutMs: timeoutMs)),
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
    try {
      final url = _apiUrl('/proxies/${Uri.encodeComponent(groupName)}');

      final response = await _apiClient
          .put(
            Uri.parse(url),
            headers: _apiHeaders(json: true),
            body: jsonEncode({'name': nodeName}),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200 || response.statusCode == 204) {
        // 关闭所有已有连接，强制新连接走新节点
        try {
          final connUrl = _apiUrl('/connections');
          await _apiClient
              .delete(Uri.parse(connUrl), headers: _apiHeaders())
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
        return true;
      }
      return false;
    } catch (e) {
      _log('切换代理失败: $e');
      return false;
    }
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
      // 轮询等待核心清空连接，最多等 250ms，提前清完提前返回
      final deadline = DateTime.now().add(const Duration(milliseconds: 250));
      while (DateTime.now().isBefore(deadline)) {
        final remaining = await _countActiveConnections();
        if (remaining == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
    return proxyOk && globalOk;
  }

  Future<bool> _switchProxyGroup(String groupName, String nodeName) async {
    try {
      final url = _apiUrl('/proxies/${Uri.encodeComponent(groupName)}');
      final response = await _apiClient
          .put(
            Uri.parse(url),
            headers: _apiHeaders(json: true),
            body: jsonEncode({'name': nodeName}),
          )
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (e) {
      _log('切换代理组失败 $groupName -> $nodeName: $e');
      return false;
    }
  }

  Future<void> _closeConnections() async {
    try {
      final connUrl = _apiUrl('/connections');
      await _apiClient
          .delete(Uri.parse(connUrl), headers: _apiHeaders())
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<int> _countActiveConnections() async {
    try {
      final response = await _apiClient
          .get(Uri.parse(_apiUrl('/connections')), headers: _apiHeaders())
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final connections = data['connections'] as List?;
        return connections?.length ?? -1;
      }
    } catch (_) {}
    return -1;
  }

  /// 切换代理模式
  Future<bool> switchMode(String mode) async {
    try {
      final url = _apiUrl('/configs');

      final response = await _apiClient
          .patch(
            Uri.parse(url),
            headers: _apiHeaders(json: true),
            body: jsonEncode({'mode': mode}),
          )
          .timeout(const Duration(seconds: 5));

      return response.statusCode == 200 || response.statusCode == 204;
    } catch (e) {
      _log('切换模式失败: $e');
      return false;
    }
  }

  /// 获取当前配置
  Future<Map<String, dynamic>?> getConfigs() async {
    try {
      final response = await _apiClient
          .get(Uri.parse(_apiUrl('/configs')), headers: _apiHeaders())
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      _log('获取配置失败: $e');
    }
    return null;
  }

  /// 状态监控
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
            'Mihomo 健康检查失败 ($_consecutiveHealthCheckFailures/'
            '$_maxConsecutiveHealthCheckFailures): $_lastHealthCheckError',
          );
          if (_consecutiveHealthCheckFailures >=
              _maxConsecutiveHealthCheckFailures) {
            _isRunning = false;
            _log('Mihomo 核心连接丢失');
            _notifyStatusChanged();
            await _stopInternal();
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
    if (_kReleaseMode) {
      onLog?.call(sanitized);
      return;
    }
    final logFile = _logFile;
    if (logFile != null) {
      final line = '[${DateTime.now().toIso8601String()}] $sanitized\n';
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
    onStatusChanged?.call();
    for (final listener in List<VoidCallback>.from(_statusListeners)) {
      listener();
    }
  }

  Future<void> _writeBytesAtomically(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  Future<bool> _fileContentMatches(File file, List<int> bytes) async {
    if (!await file.exists()) return false;
    if (await file.length() != bytes.length) return false;
    final digest = crypto.sha256.convert(await file.readAsBytes()).toString();
    final expected = crypto.sha256.convert(bytes).toString();
    return digest == expected;
  }

  Future<void> _writeStringAtomically(File file, String content) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(content, flush: true);
    await temp.rename(file.path);
  }

  Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    bool includeParentEnvironment = true,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    Process? process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        includeParentEnvironment: includeParentEnvironment,
        environment: environment,
      );
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
      final stderr = exitCode == 124 ? '命令超时' : await stderrFuture;
      return ProcessResult(process.pid, exitCode, stdout, stderr);
    } catch (_) {
      process?.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  /// 设置核心路径（用于用户自定义路径）
  void setCorePath(String path) {
    _corePath = path;
  }

  /// 检查核心文件是否存在
  bool get coreExists => File(_corePath).existsSync();

  String get corePath => _corePath;
  String get configDir => _configDir;

  /// 释放资源（HttpClient 连接池、定时器）
  void dispose() {
    _statusTimer?.cancel();
    _statusTimer = null;
    _directHttpClient.close();
    _apiClient.close();
    _statusListeners.clear();
  }
}
