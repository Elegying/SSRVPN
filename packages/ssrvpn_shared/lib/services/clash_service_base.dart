import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../constants/app_constants.dart';
import '../models/app_diagnostics.dart';
import '../models/app_settings.dart';
import '../models/proxy_node.dart';
import '../models/proxy_group.dart';
import '../models/public_ip_info.dart';
import '../models/vpn_traffic_sample.dart';
import '../runtime_notice.dart';
import 'clash_config_generator.dart';
import '../utils/log_redactor.dart';
import '../utils/health_failure_window.dart';
import '../utils/node_display_policy.dart';
import '../utils/private_node_latency_policy.dart';
import '../utils/connection_intent_tracker.dart';
import '../utils/connection_transition_queue.dart';
import '../utils/runtime_config_name_policy.dart';
import 'app_diagnostic_history_store.dart';
import 'desktop_connection_coordinator.dart';
import 'public_ip_info_service.dart';
import 'smart_rule_bundle.dart';
import 'smart_rule_signature.dart';
import 'smart_rule_recovery.dart';

part 'clash_service_connection_progress.dart';
part 'clash_service_config_support.dart';
part 'clash_service_diagnostics.dart';
part 'clash_service_runtime_support.dart';
part 'clash_service_data_plane_support.dart';
part 'clash_service_health_monitor.dart';
part 'clash_service_latency_support.dart';
part 'clash_service_rule_provider_support.dart';
part 'clash_service_traffic.dart';

enum RuntimeLogLevel { debug, info, warning, error }

typedef SwitchContextGuard = FutureOr<bool> Function();

/// Clash API 交互的公共逻辑基类
///
/// 各平台 ClashService 继承此类，只需实现：
/// - 核心进程管理（init / start / stop）
/// - 平台特定的系统代理/VPN 设置
/// - 平台特定的文件路径和资源释放
///
abstract class ClashServiceBase
    with
        _ClashConfigSupport,
        _ClashRuntimeSupport,
        _ClashDataPlaneSupport,
        _ClashDiagnosticsSupport,
        _ClashHealthSupport,
        _ClashLatencySupport,
        _ClashRuleProviderSupport {
  // ── 状态 ──
  bool _isRunning = false;
  int _trafficSessionGeneration = 0;
  final _healthFailures = HealthFailureWindow();
  final _healthClock = Stopwatch()..start();
  String? _lastHealthCheckError;
  String? _lastStartError;
  String? _lastRuntimePortAdjustmentMessage;
  final ConnectionIntentTracker _connectionIntent = ConnectionIntentTracker();
  final ConnectionTransitionQueue _connectionTransitions =
      ConnectionTransitionQueue();
  DesktopConnectionRecoveryPlan? _desktopConnectionRecoveryPlan;
  String? _desktopRecoveryPreferredNodeName;
  Future<void> _proxySelectionTail = Future<void>.value();
  int _pendingProxySelections = 0;

  AppSettings _settings = AppSettings();
  String _configDir = '';
  String _configPath = '';
  // ── HTTP 客户端 ──
  HttpClient? _directHttpClient;
  http.Client? _apiClient;

  // ── 回调 ──
  void Function()? onStatusChanged;
  void Function()? onProcessExit;
  void Function(RuntimeNotice notice)? onRuntimeNotice;
  final Set<void Function()> _statusListeners = {};

  String? _connectionProgress;
  final Set<void Function()> _connectionProgressListeners = {};
  bool _autoRecoveryInProgress = false;

  Timer? _statusTimer;
  Timer? _ruleProviderRefreshTimer;

  /// Subclasses can use this to make direct HTTP calls to the Clash API.
  @protected
  @override
  http.Client? get apiClient => _apiClient;

  @override
  Future<bool> diagnosticRecentIPv6Failure() => _readRecentIPv6TargetFailure();

  @protected
  Duration get ruleProviderStartupRefreshDelay =>
      AppConstants.ruleProviderStartupRefreshDelay;

  @protected
  bool get enablePeriodicHealthMonitor => true;

  // ── Getters ──
  @override
  bool get isRunning => _isRunning;
  Future<VpnTrafficSample?> readTrafficSample() => _readTrafficSample();
  @override
  String? get lastStartError => _lastStartError;
  @override
  String? get lastRuntimePortAdjustmentMessage =>
      _lastRuntimePortAdjustmentMessage;
  @override
  String? get lastHealthCheckError => _lastHealthCheckError;

  @protected
  @override
  void setLastHealthCheckError(String? value) {
    if (_canPublishHealthCheckResult) _lastHealthCheckError = value;
  }

  int get runtimeProxyPort => _settings.proxyPort;
  int get runtimeSocksPort => _settings.socksPort;
  @override
  int get runtimeApiPort => _settings.apiPort;
  @override
  AppSettings get settings => _settings;
  @override
  bool get connectionDesired => _connectionIntent.desired;

  /// Includes queued selections so advisory work cannot resume between them.
  bool get isProxySelectionInProgress => _pendingProxySelections > 0;
  @override
  String get configDir => _configDir;
  @override
  String get configPath => _configPath;

  int requestConnectionIntent(bool connected) {
    _connectionProgress = null;
    if (!connected) clearDesktopConnectionRecoveryPlan();
    return _connectionIntent.request(connected);
  }

  @override
  int? captureAutomaticRestartIntent() =>
      _connectionIntent.captureAutomaticRestart();

  bool isConnectionIntentCurrent(int generation, {required bool connected}) =>
      _connectionIntent.isCurrent(generation, desired: connected);

  Future<T> runConnectionTransition<T>(Future<T> Function() transition) =>
      _connectionTransitions.run(transition);

  /// Returns true once when a platform has already started a privileged
  /// replacement process and the current desktop instance should shut down.
  bool consumeTunElevationRelaunchRequest() => false;

  /// Installs the latest successful desktop connection's immutable recovery
  /// source. Callers must pass closures that capture services/snapshots only,
  /// never a widget State object.
  void rememberDesktopConnectionRecoveryPlan({
    required AppSettings preferredSettings,
    required Future<String> Function(
      AppSettings runtimeSettings,
      String? preferredNodeName,
    ) generateConfig,
    required bool Function() isRevisionCurrent,
    String? preferredNodeName,
  }) {
    final settingsSnapshot = preferredSettings.copyWith(
      forceProxySites: List<String>.of(preferredSettings.forceProxySites),
      forceDirectSites: List<String>.of(preferredSettings.forceDirectSites),
    );
    _desktopRecoveryPreferredNodeName = preferredNodeName;
    _desktopConnectionRecoveryPlan = DesktopConnectionRecoveryPlan(
      preferredSettings: settingsSnapshot,
      prepareForStart: prepareForStart,
      generateConfig: (runtimeSettings) =>
          generateConfig(runtimeSettings, _desktopRecoveryPreferredNodeName),
      writeConfig: writeDesktopRecoveryConfig,
      start: startForAutomaticRecovery,
      stop: stop,
      isRevisionCurrent: isRevisionCurrent,
      isIntentCurrent: (generation) =>
          isConnectionIntentCurrent(generation, connected: true),
      shouldRollbackStaleIntent: () => !connectionDesired,
      cancelIntent: () {
        requestConnectionIntent(false);
        interruptPendingStart();
      },
      readStartFailureReason: () => lastStartError,
      readRuntimeNotice: () => lastRuntimePortAdjustmentMessage,
      switchPreferredNode: (isConnectionContextCurrent) async {
        final currentPreferredNode = _desktopRecoveryPreferredNodeName;
        return currentPreferredNode == null
            ? true
            : switchSelectedProxy(
                currentPreferredNode,
                isSwitchContextCurrent: () =>
                    isRunning && isConnectionContextCurrent(),
              );
      },
    );
  }

  /// Invalidates only the long-lived automatic-recovery source. The active
  /// core and current connection intent are deliberately left untouched.
  void clearDesktopConnectionRecoveryPlan() {
    _desktopConnectionRecoveryPlan = null;
    _desktopRecoveryPreferredNodeName = null;
  }

  @protected
  Future<bool> recoverDesktopConnection(int connectionGeneration) async {
    final plan = _desktopConnectionRecoveryPlan;
    if (plan == null) {
      setLastStartError('缺少可验证的桌面连接配置，已阻止自动恢复');
      return false;
    }
    try {
      final result = await plan.recover(connectionGeneration);
      final connected = result.connected &&
          isRunning &&
          isConnectionIntentCurrent(connectionGeneration, connected: true);
      if (!connected && result.failureReason != null) {
        setLastStartError(result.failureReason);
      }
      return connected;
    } catch (error) {
      this.log(
        '重新生成并启动桌面连接失败: '
        'cause=${_safeRuntimeLogErrorCode(error)}',
        level: RuntimeLogLevel.error,
        event: 'health_recovery',
      );
      setLastStartError(
        '重新生成并启动桌面连接失败：'
        '${safeUserFacingFailureMessage(error)}',
      );
      return false;
    }
  }

  @protected
  Future<void> writeDesktopRecoveryConfig(String config) =>
      Future<void>.error(UnsupportedError('Config writer is not available'));

  Future<bool> start() => Future<bool>.value(false);

  Future<void> stop() => onStopRequired();

  /// A disconnected UI does not prove that proxy, DNS or process cleanup
  /// completed. Always await the platform's idempotent stop before installing.
  Future<bool> prepareForUpdateInstall() {
    final generation = requestConnectionIntent(false);
    interruptPendingStart();
    return runConnectionTransition(() async {
      if (!isConnectionIntentCurrent(generation, connected: false)) {
        return false;
      }
      await stop();
      return !isRunning &&
          isConnectionIntentCurrent(generation, connected: false);
    });
  }

  /// Desktop implementations override this to preserve the bounded recovery
  /// attempt counter. Non-desktop services retain the normal start behavior.
  @protected
  Future<bool> startForAutomaticRecovery() => start();

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
    _desiredApiPort ??= settings.apiPort;
    // Preferences and runtime identity must not share a mutable instance.
    _settings = settings.copyWith();
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
  @override
  String _apiUrl(String path) {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return 'http://127.0.0.1:$runtimeApiPort/$cleanPath';
  }

  @override
  Map<String, String> apiHeaders({bool json = false}) {
    final apiSecret = runtimeApiSecret;
    return {
      if (apiSecret.isNotEmpty) 'Authorization': 'Bearer $apiSecret',
      if (json) 'Content-Type': 'application/json',
    };
  }

  /// 获取代理节点列表
  Future<List<ProxyGroup>> getProxies() async {
    try {
      final data = await _readControllerObject('/proxies');
      if (data != null) {
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
      this.log('获取代理列表失败: cause=${_safeRuntimeLogErrorCode(e)}');
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
      this.log(
        '切换代理失败: cause=${_safeRuntimeLogErrorCode(e)}',
        level: RuntimeLogLevel.warning,
        event: 'proxy_switch',
      );
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
      this.log('切换模式失败: cause=${_safeRuntimeLogErrorCode(e)}');
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>?> getConfigs() =>
      _readControllerObject('/configs');

  /// 切换选中的代理节点（同时处理 PROXY 和 GLOBAL 组）
  /// Guard each mutation/confirmation against a stale same-port session.
  Future<bool> switchSelectedProxy(
    String nodeName, {
    SwitchContextGuard? isSwitchContextCurrent,
  }) {
    final generation = _trafficSessionGeneration;
    Future<bool> isCurrent() async =>
        generation == _trafficSessionGeneration &&
        await _isSwitchContextCurrent(isSwitchContextCurrent);
    final publishBusy = _pendingProxySelections++ == 0;
    final operation = _proxySelectionTail.then(
      (_) async {
        try {
          if (publishBusy) _notifyStatusChanged();
          return await _switchSelectedProxy(
            nodeName,
            isSwitchContextCurrent: isCurrent,
          );
        } finally {
          if (--_pendingProxySelections == 0) _notifyStatusChanged();
        }
      },
    );
    _proxySelectionTail = operation.then<void>((_) {}, onError: (_, __) {});
    return operation;
  }

  Future<bool> _switchSelectedProxy(
    String nodeName, {
    SwitchContextGuard? isSwitchContextCurrent,
  }) async {
    if (!await _isSwitchContextCurrent(isSwitchContextCurrent)) return false;
    final proxyAlreadySelected =
        await _currentProxyGroupSelection('PROXY') == nodeName;
    if (!await _isSwitchContextCurrent(isSwitchContextCurrent)) return false;
    if (proxyAlreadySelected) {
      final effectiveNode = await currentSelectedProxyName();
      if (!await _isSwitchContextCurrent(isSwitchContextCurrent)) return false;
      if (effectiveNode == nodeName) {
        // Keep in-flight DNS/exit-IP requests when startup already selected it.
        if (_desktopConnectionRecoveryPlan != null) {
          _desktopRecoveryPreferredNodeName = nodeName;
        }
        return true;
      }
    }
    final proxyOk = await _switchAndConfirmProxyGroup('PROXY', nodeName);
    if (!proxyOk) return false;
    if (!await _isSwitchContextCurrent(isSwitchContextCurrent)) return true;

    var globalOk = true;
    if (_settings.proxyMode == ProxyMode.global) {
      globalOk = await _switchAndConfirmProxyGroup('GLOBAL', 'PROXY');
      if (!await _isSwitchContextCurrent(isSwitchContextCurrent)) {
        return proxyOk && globalOk;
      }
      if (!globalOk) {
        globalOk = await _switchAndConfirmProxyGroup('GLOBAL', nodeName);
        if (!await _isSwitchContextCurrent(isSwitchContextCurrent)) {
          return proxyOk && globalOk;
        }
      }
    }
    final selectedNode = await currentSelectedProxyName();
    final effectiveOk = proxyOk && globalOk && selectedNode == nodeName;
    if (!await _isSwitchContextCurrent(isSwitchContextCurrent)) {
      return effectiveOk;
    }
    if (effectiveOk) {
      if (_desktopConnectionRecoveryPlan != null) {
        _desktopRecoveryPreferredNodeName = nodeName;
      }
      await _closeConnections();
      if (!await _isSwitchContextCurrent(isSwitchContextCurrent)) return true;
      // 轮询等待核心清空连接，最多等 250ms
      final deadline = DateTime.now().add(const Duration(milliseconds: 250));
      while (DateTime.now().isBefore(deadline)) {
        final remaining = await _countActiveConnections();
        if (remaining <= 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      if (!await _isSwitchContextCurrent(isSwitchContextCurrent)) return true;
      onDataPlaneRouteChanged();
      _notifyStatusChanged();
    }
    return effectiveOk;
  }

  Future<bool> _isSwitchContextCurrent(SwitchContextGuard? guard) async =>
      guard == null || await guard();

  /// Returns the effective node, resolving GLOBAL -> PROXY when applicable.
  @override
  Future<String?> currentSelectedProxyName() async {
    final generation = _trafficSessionGeneration;
    final global = _settings.proxyMode == ProxyMode.global;
    var selected =
        await _currentProxyGroupSelection(global ? 'GLOBAL' : 'PROXY');
    if (generation != _trafficSessionGeneration) return null;
    if (global && selected == 'PROXY') {
      selected = await _currentProxyGroupSelection('PROXY');
    }
    if (selected == null ||
        selected.trim().isEmpty ||
        RuntimeConfigNamePolicy.reservedProxyNames.contains(selected)) {
      return null;
    }
    return selected;
  }

  Future<bool> _switchAndConfirmProxyGroup(
    String groupName,
    String nodeName,
  ) async {
    final generation = _trafficSessionGeneration;
    final accepted = await _switchProxyGroup(groupName, nodeName);
    if (!accepted || generation != _trafficSessionGeneration) return false;
    return _waitForProxyGroupSelection(groupName, nodeName);
  }

  Future<bool> _switchProxyGroup(String groupName, String nodeName) async {
    try {
      final client = _apiClient;
      if (client == null) {
        this.log(
          '切换代理组失败: 本地 API 客户端未初始化',
          level: RuntimeLogLevel.warning,
          event: 'proxy_switch',
        );
        return false;
      }
      final url = _apiUrl('/proxies/${Uri.encodeComponent(groupName)}');
      final response = await client
          .put(
            Uri.parse(url),
            headers: apiHeaders(json: true),
            body: jsonEncode({'name': nodeName}),
          )
          .timeout(const Duration(seconds: 5));
      final accepted = response.statusCode == 200 || response.statusCode == 204;
      if (!accepted) {
        this.log(
          '切换代理组未被核心接受: group=$groupName, '
          'HTTP ${response.statusCode}',
          level: RuntimeLogLevel.warning,
          event: 'proxy_switch',
        );
      }
      return accepted;
    } catch (e) {
      this.log(
        '切换代理组失败 $groupName -> $nodeName: '
        'cause=${_safeRuntimeLogErrorCode(e)}',
        level: RuntimeLogLevel.warning,
        event: 'proxy_switch',
      );
      return false;
    }
  }

  Future<String?> _currentProxyGroupSelection(String groupName) async {
    final data = await _readControllerObject(
      '/proxies/${Uri.encodeComponent(groupName)}',
      timeout: const Duration(seconds: 3),
    );
    return data?['now']?.toString();
  }

  Future<bool> _waitForProxyGroupSelection(
    String groupName,
    String expectedNodeName,
  ) async {
    String? lastSeen;
    final generation = _trafficSessionGeneration;
    final deadline = DateTime.now().add(const Duration(milliseconds: 500));
    while (DateTime.now().isBefore(deadline)) {
      if (generation != _trafficSessionGeneration) return false;
      lastSeen = await _currentProxyGroupSelection(groupName);
      if (generation != _trafficSessionGeneration) return false;
      if (lastSeen == expectedNodeName) return true;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    this.log(
      '代理组状态未生效 $groupName: '
      'expected=$expectedNodeName, actual=$lastSeen',
      level: RuntimeLogLevel.warning,
      event: 'proxy_switch',
    );
    return false;
  }

  Future<void> _closeConnections() async {
    try {
      final client = _apiClient;
      if (client == null) return;
      final connUrl = _apiUrl('/connections');
      final response = await client
          .delete(Uri.parse(connUrl), headers: apiHeaders())
          .timeout(const Duration(seconds: 3));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        this.log(
          '节点已切换，但旧连接清理请求未被核心接受: '
          'HTTP ${response.statusCode}',
          level: RuntimeLogLevel.warning,
          event: 'connection_cleanup',
        );
      }
    } catch (error) {
      this.log(
        '节点已切换，但旧连接清理未完成: '
        'cause=${_safeRuntimeLogErrorCode(error)}',
        level: RuntimeLogLevel.warning,
        event: 'connection_cleanup',
      );
    }
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

  // ── 状态监控 ──

  /// 子类实现：当健康检查连续失败时需要停止核心
  Future<void> onStopRequired();

  /// Gives a platform one bounded, generation-aware opportunity to recover a
  /// core or service whose control plane stayed unhealthy. The default keeps
  /// backward compatibility: it performs the required cleanup and reports a
  /// recovery only if the platform deliberately left itself running.
  @protected
  Future<bool> recoverAfterHealthCheckFailure(int connectionGeneration) async {
    if (await boundedHealthCheck()) {
      setRunning(true);
      return isConnectionIntentCurrent(connectionGeneration, connected: true);
    }
    await onStopRequired();
    return _isRunning &&
        isConnectionIntentCurrent(connectionGeneration, connected: true);
  }

  // ── 状态管理 ──

  void setRunning(bool running) {
    if (_isRunning != running) {
      _healthFailures.reset();
      _trafficSessionGeneration++;
      _invalidateHealthMonitorSession();
      _resetDataPlaneObservationSession();
    }
    _isRunning = running;
  }

  /// Records an unexpected core loss. Unlike an intentional stop during an
  /// automatic reload, this must also cancel the user's previous connect
  /// intent so tray/UI actions do not require a second disconnect click.
  @protected
  void markConnectionLost() {
    requestConnectionIntent(false);
    _invalidateHealthMonitorSession();
    _resetDataPlaneObservationSession();
    _isRunning = false;
    _notifyStatusChanged();
  }

  void setLastStartError(String? error) {
    _lastStartError = error;
  }

  void resetHealthCheckFailures() {
    _healthFailures.reset();
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

  @override
  void notifyStatusChanged() {
    _notifyStatusChanged();
  }

  @protected
  void notifyRuntimeNotice(RuntimeNotice notice) {
    onRuntimeNotice?.call(notice);
  }

  // ── 资源释放 ──

  void dispose() {
    stopStatusMonitor();
    clearDesktopConnectionRecoveryPlan();
    _directHttpClient?.close();
    _apiClient?.close();
    onRuntimeNotice = null;
    _statusListeners.clear();
    _connectionProgressListeners.clear();
  }
}
