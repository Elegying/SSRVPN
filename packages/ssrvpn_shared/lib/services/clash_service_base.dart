import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../constants/app_constants.dart';
import '../models/app_settings.dart';
import '../models/proxy_node.dart';
import '../models/proxy_group.dart';
import 'clash_config_generator.dart';
import '../utils/log_redactor.dart';
import '../utils/private_node_latency_policy.dart';

/// Clash API 交互的公共逻辑基类
///
/// 各平台 ClashService 继承此类，只需实现：
/// - 核心进程管理（init / start / stop）
/// - 平台特定的系统代理/VPN 设置
/// - 平台特定的文件路径和资源释放
///
/// 公共能力（API 调用、延迟测试、日志、状态管理）全部在此实现。
abstract class ClashServiceBase {
  // ── 状态 ──
  bool _isRunning = false;
  bool _healthCheckInProgress = false;
  int _consecutiveHealthCheckFailures = 0;
  static const int _maxConsecutiveHealthCheckFailures = 3;
  String? _lastHealthCheckError;
  String? _lastStartError;

  AppSettings _settings = AppSettings();
  String _configDir = '';
  String _configPath = '';
  String _logBuffer = '';
  _ClashConfigCacheKey? _lastGeneratedConfigKey;
  String? _lastGeneratedConfig;

  // ── HTTP 客户端 ──
  HttpClient? _directHttpClient;
  http.Client? _apiClient;

  // ── 回调 ──
  void Function()? onStatusChanged;
  void Function()? onProcessExit;
  void Function(String message)? onLog;
  final Set<void Function()> _statusListeners = {};

  // ── 定时器 ──
  Timer? _statusTimer;
  Timer? _ruleProviderRefreshTimer;

  // ── Protected API ──

  /// Subclasses can use this to make direct HTTP calls to the Clash API.
  @protected
  http.Client? get apiClient => _apiClient;

  @protected
  Duration get ruleProviderStartupRefreshDelay =>
      AppConstants.ruleProviderStartupRefreshDelay;

  // ── Getters ──
  bool get isRunning => _isRunning;
  String? get lastStartError => _lastStartError;
  String get recentLogs => _logBuffer;
  int get runtimeProxyPort => _settings.proxyPort;
  int get runtimeSocksPort => _settings.socksPort;
  int get runtimeApiPort => _settings.apiPort;
  AppSettings get settings => _settings;
  String get configDir => _configDir;
  String get configPath => _configPath;

  // ── 初始化 ──

  void initHttpClient() {
    _directHttpClient = HttpClient();
    _directHttpClient!.findProxy = (_) => 'DIRECT';
    _directHttpClient!.connectionTimeout = const Duration(seconds: 3);
    _apiClient = IOClient(_directHttpClient!);
  }

  void updateSettings(AppSettings settings) {
    _settings = settings;
  }

  void setPaths({required String configDir, required String configPath}) {
    _configDir = configDir;
    _configPath = configPath;
  }

  @protected
  String buildClashConfig(
    String rawYaml,
    AppSettings settings, {
    required String platformHeader,
    String? preferredNodeName,
    String? tunConfig,
    String? latencyTestUrl,
    bool includeFallbackGroup = false,
    bool includeGeoIpRules = false,
    Iterable<String> extraSelectGroupNames = const [],
    Iterable<String> extraRulesBeforeDirect = const [],
  }) {
    final preferredNode = preferredNodeName ?? settings.lastSelectedNodeName;
    final extraGroups = List<String>.unmodifiable(extraSelectGroupNames);
    final extraRules = List<String>.unmodifiable(extraRulesBeforeDirect);
    final cacheKey = _ClashConfigCacheKey(
      rawYaml: rawYaml,
      settings: settings,
      preferredNodeName: preferredNode,
      platformHeader: platformHeader,
      tunConfig: tunConfig,
      latencyTestUrl: latencyTestUrl,
      includeFallbackGroup: includeFallbackGroup,
      includeGeoIpRules: includeGeoIpRules,
      extraSelectGroupNames: extraGroups,
      extraRulesBeforeDirect: extraRules,
    );
    if (_lastGeneratedConfigKey == cacheKey && _lastGeneratedConfig != null) {
      return _lastGeneratedConfig!;
    }

    final output = ClashConfigGenerator.generateConfig(
      rawYaml,
      settings,
      preferredNodeName: preferredNode,
      platformHeader: platformHeader,
      tunConfig: tunConfig,
      latencyTestUrl: latencyTestUrl,
      includeFallbackGroup: includeFallbackGroup,
      includeGeoIpRules: includeGeoIpRules,
      extraSelectGroupNames: extraGroups,
      extraRulesBeforeDirect: extraRules,
    );
    _lastGeneratedConfigKey = cacheKey;
    _lastGeneratedConfig = output;
    return output;
  }

  // ── YAML 工具 ──

  /// 从原始 YAML 提取指定顶层段的原始内容
  String extractSection(String yaml, String sectionName) {
    if (sectionName == 'proxies') {
      return ClashConfigGenerator.buildProxiesText(yaml);
    }

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

  /// 提取代理名称列表（loadYaml 解析，失败时 fallback 纯文本）
  List<String> extractProxyNames(String rawYaml) {
    return ClashConfigGenerator.extractProxyNames(rawYaml);
  }

  /// 纯文本方式提取代理名称（fallback）
  List<String> extractProxyNamesFromText(String rawYaml) {
    final names = <String>[];
    try {
      final proxiesSection = extractSection(rawYaml, 'proxies');
      for (final line in proxiesSection.split('\n')) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('-')) continue;
        final nameMatch = RegExp(
          r'''name:\s*['"]?([^'"\n,]+)['"]?''',
        ).firstMatch(trimmed);
        if (nameMatch != null) names.add(nameMatch.group(1)!.trim());
      }
    } catch (_) {}
    return names;
  }

  /// YAML 单引号字符串转义（过滤控制字符和反斜杠）
  String yamlQuote(String name) {
    final sanitized = name
        .replaceAll('\\', '\\\\')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    return "'${sanitized.replaceAll("'", "''")}'";
  }

  // ── Clash API ──

  String _apiUrl(String path) {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return 'http://127.0.0.1:${_settings.apiPort}/$cleanPath';
  }

  Map<String, String> apiHeaders({bool json = false}) {
    return {
      if (_settings.apiSecret.isNotEmpty)
        'Authorization': 'Bearer ${_settings.apiSecret}',
      if (json) 'Content-Type': 'application/json',
    };
  }

  @protected
  Future<void> refreshRuleProvidersOnce() async {
    if (!_isRunning) return;
    final client = _apiClient;
    if (client == null) return;

    for (final providerName in AppConstants.ruleProviderNames) {
      if (!_isRunning) return;
      try {
        final response = await client
            .put(
              Uri.parse(
                _apiUrl(
                    '/providers/rules/${Uri.encodeComponent(providerName)}'),
              ),
              headers: apiHeaders(),
            )
            .timeout(AppConstants.apiTimeout);
        if (response.statusCode == 200 || response.statusCode == 204) {
          log('规则集已检查更新: $providerName');
        } else {
          log('规则集更新检查失败 $providerName: HTTP ${response.statusCode}');
        }
      } catch (e) {
        log('规则集更新检查失败 $providerName: $e');
      }
    }
  }

  /// 获取代理节点列表
  Future<List<ProxyGroup>> getProxies() async {
    try {
      final client = _apiClient;
      if (client == null) return [];
      final response = await client
          .get(Uri.parse(_apiUrl('/proxies')), headers: apiHeaders())
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
            final allNames = (proxyData['all'] as List?)?.cast<String>() ?? [];
            final nodes = <ProxyNode>[];
            for (final name in allNames) {
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
      log('获取代理列表失败: $e');
    }
    return [];
  }

  /// 切换代理节点
  Future<bool> switchProxy(String groupName, String nodeName) async {
    try {
      final client = _apiClient;
      if (client == null) return false;
      final url = _apiUrl('/proxies/${Uri.encodeComponent(groupName)}');
      final response = await client
          .put(
            Uri.parse(url),
            headers: apiHeaders(json: true),
            body: jsonEncode({'name': nodeName}),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200 || response.statusCode == 204) {
        await _closeConnections();
        return true;
      }
      return false;
    } catch (e) {
      log('切换代理失败: $e');
      return false;
    }
  }

  /// 切换代理模式
  Future<bool> switchMode(String mode) async {
    try {
      final client = _apiClient;
      if (client == null) return false;
      final url = _apiUrl('/configs');
      final response = await client
          .patch(
            Uri.parse(url),
            headers: apiHeaders(json: true),
            body: jsonEncode({'mode': mode}),
          )
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (e) {
      log('切换模式失败: $e');
      return false;
    }
  }

  /// 获取当前配置
  Future<Map<String, dynamic>?> getConfigs() async {
    try {
      final client = _apiClient;
      if (client == null) return null;
      final response = await client
          .get(Uri.parse(_apiUrl('/configs')), headers: apiHeaders())
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      log('获取配置失败: $e');
    }
    return null;
  }

  /// 切换选中的代理节点（同时处理 PROXY 和 GLOBAL 组）
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
      // 轮询等待核心清空连接，最多等 250ms
      final deadline = DateTime.now().add(const Duration(milliseconds: 250));
      while (DateTime.now().isBefore(deadline)) {
        final remaining = await _countActiveConnections();
        if (remaining <= 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
    return proxyOk && globalOk;
  }

  Future<bool> _switchProxyGroup(String groupName, String nodeName) async {
    try {
      final client = _apiClient;
      if (client == null) return false;
      final url = _apiUrl('/proxies/${Uri.encodeComponent(groupName)}');
      final response = await client
          .put(
            Uri.parse(url),
            headers: apiHeaders(json: true),
            body: jsonEncode({'name': nodeName}),
          )
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (e) {
      log('切换代理组失败 $groupName -> $nodeName: $e');
      return false;
    }
  }

  Future<void> _closeConnections() async {
    try {
      final client = _apiClient;
      if (client == null) return;
      final connUrl = _apiUrl('/connections');
      await client
          .delete(Uri.parse(connUrl), headers: apiHeaders())
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<int> _countActiveConnections() async {
    try {
      final client = _apiClient;
      if (client == null) return -1;
      final response = await client
          .get(Uri.parse(_apiUrl('/connections')), headers: apiHeaders())
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final connections = data['connections'] as List?;
        return connections?.length ?? -1;
      }
    } catch (_) {}
    return -1;
  }

  // ── 延迟测试 ──

  /// 测试节点延迟（直连 TCP）
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

  /// 批量测试节点延迟
  Future<void> testAllLatencies(
    List<ProxyNode> nodes,
    void Function(String name, int latency) onResult, {
    int concurrency = 10,
    int timeoutMs = 5000,
  }) async {
    final random = Random();
    for (var i = 0; i < nodes.length; i += concurrency) {
      final batch = nodes.skip(i).take(concurrency).toList();
      final results = await Future.wait(
        batch.map(
          (node) => testLatency(node.server, node.port, timeoutMs: timeoutMs),
        ),
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

  // ── 连通性验证 ──

  /// 验证用户连通性（通过代理访问 generate_204）
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

  /// 解析当前出口国家代码
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
          final normalized = normalizeCountryCode(country);
          if (normalized != null) return normalized;
        } catch (_) {}
      }
      return null;
    } finally {
      client.close();
    }
  }

  String? normalizeCountryCode(String? value) {
    final code = value?.trim().toUpperCase() ?? '';
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(code)) return null;
    if (code == 'UK') return 'GB';
    if (code == 'EL') return 'GR';
    return code;
  }

  // ── 健康检查 ──

  /// 健康检查（HTTP 请求验证 API 可用性）
  Future<bool> healthCheck() async {
    try {
      final client = _apiClient;
      if (client == null) return false;
      final response = await client
          .get(Uri.parse(_apiUrl('/version')), headers: apiHeaders())
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

  // ── 状态监控 ──

  void startStatusMonitor() {
    _statusTimer?.cancel();
    _scheduleRuleProviderRefreshOnce();
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_isRunning || _healthCheckInProgress) return;
      _healthCheckInProgress = true;
      try {
        final healthy = await healthCheck();
        if (healthy) {
          _consecutiveHealthCheckFailures = 0;
        } else if (_isRunning) {
          _consecutiveHealthCheckFailures++;
          log(
            'Mihomo 健康检查失败 ($_consecutiveHealthCheckFailures/'
            '$_maxConsecutiveHealthCheckFailures): $_lastHealthCheckError',
          );
          if (_consecutiveHealthCheckFailures >=
              _maxConsecutiveHealthCheckFailures) {
            _isRunning = false;
            log('Mihomo 核心连接丢失');
            _notifyStatusChanged();
            await onStopRequired();
          }
        }
      } finally {
        _healthCheckInProgress = false;
      }
    });
  }

  void stopStatusMonitor() {
    _statusTimer?.cancel();
    _statusTimer = null;
    _ruleProviderRefreshTimer?.cancel();
    _ruleProviderRefreshTimer = null;
  }

  void _scheduleRuleProviderRefreshOnce() {
    _ruleProviderRefreshTimer?.cancel();
    if (!_isRunning) return;

    _ruleProviderRefreshTimer = Timer(ruleProviderStartupRefreshDelay, () {
      _ruleProviderRefreshTimer = null;
      unawaited(refreshRuleProvidersOnce());
    });
  }

  /// 子类实现：当健康检查连续失败时需要停止核心
  Future<void> onStopRequired();

  // ── 日志 ──

  static const bool _kReleaseMode = bool.fromEnvironment('dart.vm.product');

  void log(String message) {
    final sanitized = LogRedactor.sanitize(message);
    _logBuffer = '$sanitized\n$_logBuffer';
    if (_logBuffer.length > 10000) _logBuffer = _logBuffer.substring(0, 10000);
    onLog?.call(sanitized);
    if (!_kReleaseMode) {
      debugLog(sanitized);
    }
  }

  /// Override for platform-specific debug output (debugPrint, file logging, etc.)
  @protected
  void debugLog(String message) {}

  // ── 状态管理 ──

  void setRunning(bool running) {
    _isRunning = running;
  }

  void setLastStartError(String? error) {
    _lastStartError = error;
  }

  void resetHealthCheckFailures() {
    _consecutiveHealthCheckFailures = 0;
  }

  void addStatusListener(void Function() listener) {
    _statusListeners.add(listener);
  }

  void removeStatusListener(void Function() listener) {
    _statusListeners.remove(listener);
  }

  void _notifyStatusChanged() {
    onStatusChanged?.call();
    for (final listener in List<void Function()>.from(_statusListeners)) {
      listener();
    }
  }

  void notifyStatusChanged() {
    _notifyStatusChanged();
  }

  // ── 文件工具 ──

  Future<void> writeStringAtomically(File file, String content) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(content, flush: true);
    await temp.rename(file.path);
  }

  Future<void> writeBytesAtomically(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  // ── 端口工具 ──

  /// Resolves transient port conflicts without changing saved preferences.
  Future<AppSettings> prepareForStart(AppSettings preferred) async {
    final reserved = <int>{};
    final proxyPort = await findAvailablePort(preferred.proxyPort, reserved);
    reserved.add(proxyPort);
    final socksPort = await findAvailablePort(preferred.socksPort, reserved);
    reserved.add(socksPort);
    final apiPort = await findAvailablePort(preferred.apiPort, reserved);

    final runtime = preferred.copyWith(
      proxyPort: proxyPort,
      socksPort: socksPort,
      apiPort: apiPort,
    );
    _settings = runtime;

    if (proxyPort != preferred.proxyPort ||
        socksPort != preferred.socksPort ||
        apiPort != preferred.apiPort) {
      log(
        '检测到端口占用，已为本次连接自动调整: '
        '代理 ${preferred.proxyPort}->$proxyPort, '
        'SOCKS ${preferred.socksPort}->$socksPort, '
        'API ${preferred.apiPort}->$apiPort',
      );
    } else {
      log('端口检查通过: $proxyPort / $socksPort / $apiPort');
    }
    return runtime;
  }

  Future<int> findAvailablePort(int preferred, Set<int> reserved) async {
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

  // ── 资源释放 ──

  void dispose() {
    stopStatusMonitor();
    _directHttpClient?.close();
    _apiClient?.close();
    _statusListeners.clear();
  }
}

class _ClashConfigCacheKey {
  final String rawYaml;
  final AppSettings settings;
  final String? preferredNodeName;
  final String platformHeader;
  final String? tunConfig;
  final String? latencyTestUrl;
  final bool includeFallbackGroup;
  final bool includeGeoIpRules;
  final List<String> extraSelectGroupNames;
  final List<String> extraRulesBeforeDirect;

  const _ClashConfigCacheKey({
    required this.rawYaml,
    required this.settings,
    required this.preferredNodeName,
    required this.platformHeader,
    required this.tunConfig,
    required this.latencyTestUrl,
    required this.includeFallbackGroup,
    required this.includeGeoIpRules,
    required this.extraSelectGroupNames,
    required this.extraRulesBeforeDirect,
  });

  @override
  bool operator ==(Object other) {
    return other is _ClashConfigCacheKey &&
        other.rawYaml == rawYaml &&
        other.settings == settings &&
        other.preferredNodeName == preferredNodeName &&
        other.platformHeader == platformHeader &&
        other.tunConfig == tunConfig &&
        other.latencyTestUrl == latencyTestUrl &&
        other.includeFallbackGroup == includeFallbackGroup &&
        other.includeGeoIpRules == includeGeoIpRules &&
        _stringListEquals(other.extraSelectGroupNames, extraSelectGroupNames) &&
        _stringListEquals(other.extraRulesBeforeDirect, extraRulesBeforeDirect);
  }

  @override
  int get hashCode => Object.hash(
        rawYaml,
        settings,
        preferredNodeName,
        platformHeader,
        tunConfig,
        latencyTestUrl,
        includeFallbackGroup,
        includeGeoIpRules,
        Object.hashAll(extraSelectGroupNames),
        Object.hashAll(extraRulesBeforeDirect),
      );
}

bool _stringListEquals(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
