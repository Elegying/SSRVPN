import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../constants/app_constants.dart';
import '../models/app_diagnostics.dart';
import '../models/app_settings.dart';
import '../models/proxy_node.dart';
import '../models/proxy_group.dart';
import '../models/public_ip_info.dart';
import 'clash_config_generator.dart';
import '../utils/log_redactor.dart';
import '../utils/private_node_latency_policy.dart';
import '../utils/connection_intent_tracker.dart';
import '../utils/connection_transition_queue.dart';
import 'public_ip_info_service.dart';

part 'clash_service_config_support.dart';
part 'clash_service_diagnostics.dart';
part 'clash_service_runtime_support.dart';

/// Clash API 交互的公共逻辑基类
///
/// 各平台 ClashService 继承此类，只需实现：
/// - 核心进程管理（init / start / stop）
/// - 平台特定的系统代理/VPN 设置
/// - 平台特定的文件路径和资源释放
///
/// 公共能力（API 调用、延迟测试、日志、状态管理）全部在此实现。
abstract class ClashServiceBase
    with _ClashConfigSupport, _ClashRuntimeSupport, _ClashDiagnosticsSupport {
  // ── 状态 ──
  bool _isRunning = false;
  bool _healthCheckInProgress = false;
  int _consecutiveHealthCheckFailures = 0;
  String? _lastHealthCheckError;
  String? _lastStartError;
  String? _lastRuntimePortAdjustmentMessage;
  final ConnectionIntentTracker _connectionIntent = ConnectionIntentTracker();
  final ConnectionTransitionQueue _connectionTransitions =
      ConnectionTransitionQueue();
  Future<void> _proxySelectionTail = Future<void>.value();

  AppSettings _settings = AppSettings();
  String _configDir = '';
  String _configPath = '';
  String _logBuffer = '';
  // ── HTTP 客户端 ──
  HttpClient? _directHttpClient;
  http.Client? _apiClient;

  // ── 回调 ──
  void Function()? onStatusChanged;
  void Function()? onProcessExit;
  void Function(String message)? onRuntimeNotice;
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

  @protected
  Duration get statusMonitorInterval => const Duration(seconds: 5);

  @protected
  int get maxConsecutiveHealthCheckFailures => 3;

  @protected
  bool get enablePeriodicHealthMonitor => true;

  // ── Getters ──
  @override
  bool get isRunning => _isRunning;
  @override
  String? get lastStartError => _lastStartError;
  @override
  String? get lastRuntimePortAdjustmentMessage =>
      _lastRuntimePortAdjustmentMessage;
  String? get lastHealthCheckError => _lastHealthCheckError;

  @protected
  void setLastHealthCheckError(String? value) {
    _lastHealthCheckError = value;
  }

  @override
  String get recentLogs => _logBuffer;
  int get runtimeProxyPort => _settings.proxyPort;
  int get runtimeSocksPort => _settings.socksPort;
  int get runtimeApiPort => _settings.apiPort;
  AppSettings get settings => _settings;
  bool get connectionDesired => _connectionIntent.desired;
  String get configDir => _configDir;
  @override
  String get configPath => _configPath;

  int requestConnectionIntent(bool connected) =>
      _connectionIntent.request(connected);

  int? captureAutomaticRestartIntent() =>
      _connectionIntent.captureAutomaticRestart();

  bool isConnectionIntentCurrent(int generation, {required bool connected}) =>
      _connectionIntent.isCurrent(generation, desired: connected);

  Future<T> runConnectionTransition<T>(Future<T> Function() transition) =>
      _connectionTransitions.run(transition);

  /// Synchronously asks an in-flight platform start to abort.
  ///
  /// Disconnect callers must invoke this before queueing [stop]. That lets a
  /// cancellable start release the transition queue immediately instead of
  /// forcing the cleanup operation to wait behind the work it needs to stop.
  /// Platforms without a cancellable start can keep the default no-op.
  void interruptPendingStart() {}

  // ── 初始化 ──

  void initHttpClient() {
    _directHttpClient = HttpClient();
    _directHttpClient!.findProxy = (_) => 'DIRECT';
    _directHttpClient!.connectionTimeout = const Duration(seconds: 3);
    _apiClient = IOClient(_directHttpClient!);
  }

  @override
  void updateSettings(AppSettings settings) {
    _settings = settings;
  }

  @override
  void setRuntimePortAdjustmentMessage(String? message) {
    _lastRuntimePortAdjustmentMessage = message;
  }

  void setPaths({required String configDir, required String configPath}) {
    _configDir = configDir;
    _configPath = configPath;
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
      final switched = await _switchAndConfirmProxyGroup(groupName, nodeName);
      if (switched) {
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
  Future<bool> switchSelectedProxy(String nodeName) {
    final operation = _proxySelectionTail.then(
      (_) => _switchSelectedProxy(nodeName),
    );
    _proxySelectionTail = operation.then<void>((_) {}, onError: (_, __) {});
    return operation;
  }

  Future<bool> _switchSelectedProxy(String nodeName) async {
    final proxyOk = await _switchAndConfirmProxyGroup('PROXY', nodeName);
    var globalOk = true;
    if (_settings.proxyMode == ProxyMode.global) {
      globalOk = await _switchAndConfirmProxyGroup('GLOBAL', 'PROXY');
      if (!globalOk) {
        globalOk = await _switchAndConfirmProxyGroup('GLOBAL', nodeName);
      }
    }
    final effectiveOk =
        proxyOk && globalOk && (await currentSelectedProxyName()) == nodeName;
    if (effectiveOk) {
      await _closeConnections();
      // 轮询等待核心清空连接，最多等 250ms
      final deadline = DateTime.now().add(const Duration(milliseconds: 250));
      while (DateTime.now().isBefore(deadline)) {
        final remaining = await _countActiveConnections();
        if (remaining <= 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
    return effectiveOk;
  }

  /// Returns the node that Mihomo is actually routing through right now.
  ///
  /// In global mode GLOBAL may point at PROXY, so the effective node is then
  /// PROXY.now rather than GLOBAL.now itself.
  Future<String?> currentSelectedProxyName() async {
    final proxyNow = await _currentProxyGroupSelection('PROXY');
    if (_settings.proxyMode != ProxyMode.global) return _nonEmpty(proxyNow);

    final globalNow = await _currentProxyGroupSelection('GLOBAL');
    if (globalNow == null || globalNow.isEmpty || globalNow == 'PROXY') {
      return _nonEmpty(proxyNow);
    }
    if (globalNow == 'DIRECT' || globalNow == 'REJECT') return null;
    return globalNow;
  }

  Future<bool> _switchAndConfirmProxyGroup(
    String groupName,
    String nodeName,
  ) async {
    final accepted = await _switchProxyGroup(groupName, nodeName);
    if (!accepted) return false;
    return _waitForProxyGroupSelection(groupName, nodeName);
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

  Future<String?> _currentProxyGroupSelection(String groupName) async {
    try {
      final client = _apiClient;
      if (client == null) return null;
      final response = await client
          .get(
            Uri.parse(_apiUrl('/proxies/${Uri.encodeComponent(groupName)}')),
            headers: apiHeaders(),
          )
          .timeout(const Duration(seconds: 3));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded['now']?.toString();
      }
    } catch (e) {
      log('读取代理组状态失败 $groupName: $e');
    }
    return null;
  }

  Future<bool> _waitForProxyGroupSelection(
    String groupName,
    String expectedNodeName,
  ) async {
    String? lastSeen;
    final deadline = DateTime.now().add(const Duration(milliseconds: 500));
    while (DateTime.now().isBefore(deadline)) {
      lastSeen = await _currentProxyGroupSelection(groupName);
      if (lastSeen == expectedNodeName) return true;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    log(
      '代理组状态未生效 $groupName: expected=$expectedNodeName, actual=$lastSeen',
    );
    return false;
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
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
    bool Function()? shouldContinue,
  }) async {
    final random = Random();
    for (var i = 0; i < nodes.length; i += concurrency) {
      if (shouldContinue?.call() == false) return;
      final batch = nodes.skip(i).take(concurrency).toList();
      final results = await Future.wait(
        batch.map(
          (node) => testLatency(node.server, node.port, timeoutMs: timeoutMs),
        ),
      );
      for (var j = 0; j < batch.length; j++) {
        if (shouldContinue?.call() == false) return;
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

  String _localHttpProxyConfig() => 'PROXY 127.0.0.1:${_settings.proxyPort}';

  @visibleForTesting
  String userConnectivityProxyConfig() =>
      _settings.enableTun ? 'DIRECT' : _localHttpProxyConfig();

  /// 验证用户连通性。系统代理模式通过本地 mixed-port 探测；TUN 模式
  /// 必须走普通系统网络路径，才能覆盖路由和系统 DNS 泄漏。
  ///
  /// 核心/TUN 刚启动时 DNS 和连接池仍可能预热，单次 5xx 或超时不能判定
  /// 节点不可用；只有连续失败才返回非阻断提示。
  Future<String?> verifyUserConnectivity({
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 2),
    Future<http.Response> Function(Uri uri)? request,
    bool Function()? shouldContinue,
  }) async {
    IOClient? client;
    if (request == null) {
      client = IOClient(
        HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..findProxy = (_) => userConnectivityProxyConfig(),
      );
    }
    final send = request ??
        (Uri uri) => client!.get(uri).timeout(const Duration(seconds: 6));
    final attempts = maxAttempts.clamp(1, 5).toInt();
    final endpoint = Uri.parse(
      _settings.enableTun
          ? AppConstants.tunConnectivityTestUrl
          : AppConstants.defaultLatencyTestUrl,
    );
    int? lastStatusCode;
    try {
      for (var attempt = 1; attempt <= attempts; attempt++) {
        if (shouldContinue?.call() == false) return null;
        try {
          final response = await send(endpoint);
          if (shouldContinue?.call() == false) return null;
          if (response.statusCode == 204 || response.statusCode == 200) {
            return null;
          }
          lastStatusCode = response.statusCode;
        } catch (_) {
          lastStatusCode = null;
        }
        if (attempt < attempts && retryDelay > Duration.zero) {
          await Future<void>.delayed(retryDelay);
        }
      }
      if (shouldContinue?.call() == false) return null;
      if (lastStatusCode != null) {
        return '已连接，但连续 $attempts 次网络验证返回 HTTP '
            '$lastStatusCode，请尝试切换节点';
      }
      return '已连接，但连续 $attempts 次网络验证失败，请尝试切换节点或刷新订阅';
    } finally {
      client?.close();
    }
  }

  Future<PublicIpInfo> fetchCurrentPublicIpInfo() async {
    final client = IOClient(
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..findProxy = (_) => _localHttpProxyConfig(),
    );
    try {
      return await PublicIpInfoService(client: client).fetch();
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
  @override
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
    if (!enablePeriodicHealthMonitor) {
      _statusTimer = null;
      return;
    }
    _statusTimer = Timer.periodic(statusMonitorInterval, (_) async {
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
            '$maxConsecutiveHealthCheckFailures): $_lastHealthCheckError',
          );
          if (_consecutiveHealthCheckFailures >=
              maxConsecutiveHealthCheckFailures) {
            markConnectionLost();
            log('Mihomo 核心连接丢失');
            try {
              await onStopRequired();
            } catch (error) {
              log('Mihomo 丢失后的清理失败: $error');
            }
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

  @override
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

  /// Records an unexpected core loss. Unlike an intentional stop during an
  /// automatic reload, this must also cancel the user's previous connect
  /// intent so tray/UI actions do not require a second disconnect click.
  @protected
  void markConnectionLost() {
    _connectionIntent.request(false);
    _isRunning = false;
    _notifyStatusChanged();
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

  @protected
  void notifyRuntimeNotice(String message) {
    onRuntimeNotice?.call(message);
  }

  // ── 资源释放 ──

  void dispose() {
    stopStatusMonitor();
    _directHttpClient?.close();
    _apiClient?.close();
    onRuntimeNotice = null;
    _statusListeners.clear();
  }
}
