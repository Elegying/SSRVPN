import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_shared/runtime_notice.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

part 'clash_service_snapshot_cleanup.dart';
part 'clash_service_native_bridge.dart';
part 'clash_service_config.dart';
part 'clash_service_country.dart';

class _AndroidStartCancelled implements Exception {}

/// Clash Meta 核心管理服务 (Android 版)
///
/// 继承 [ClashServiceBase] 共享 API/延迟/健康检查/状态/端口，
/// 仅实现 Android 特有：MethodChannel 桥接、gomobile VPN 启停、
/// MMDB 解压、TUN 配置、磁贴/通知集成。
class ClashService extends ClashServiceBase {
  static const _channel = MethodChannel('com.ssrvpn/native');

  String _corePath = '';
  String _nativeLibDir = '';
  Future<bool>? _startOperation;
  Future<void>? _stopOperation;
  final CoreRecoveryPolicy _healthRecoveryPolicy = CoreRecoveryPolicy(
    maxAttempts: 2,
  );
  Future<void> _nativeSnapshotOperationTail = Future<void>.value();
  int _nativeSnapshotOperationCount = 0;
  String? _nativeSnapshotConfigPath;
  String? _nativeSnapshotGeneration;
  int _startGeneration = 0;
  int _configRevision = 0;
  int _nativeStateEpoch = 0;
  Timer? _nativeStateReconciliationTimer;
  int? _nativeSessionGeneration;
  bool _nativeSessionProtocolAvailable = false;
  bool _nativeConnectionTransitioning = false;
  bool? _underlyingNetworkAvailable;
  bool? _underlyingNetworkValidated;
  String? _runningConfigPath;
  final Set<String> _preparedConfigPaths = <String>{};
  bool _intentionalReloadInProgress = false;

  /// 磁贴/通知触发的自动连接回调
  VoidCallback? onAutoConnect;

  String get corePath => _corePath;
  bool get coreExists => File(_corePath).existsSync();
  bool get nativeConnectionTransitioning => _nativeConnectionTransitioning;
  int? get nativeSessionGeneration => _nativeSessionGeneration;
  String? get underlyingNetworkNotice {
    if (!isRunning) return null;
    if (_underlyingNetworkAvailable == false) {
      return '无可用网络，VPN 正在等待恢复';
    }
    if (_underlyingNetworkAvailable == true &&
        _underlyingNetworkValidated == false) {
      return '网络尚未验证，VPN 正在等待恢复';
    }
    return connectivityWarning;
  }

  void setCorePath(String path) => _corePath = path;

  Future<T> runIntentionalReloadTransition<T>(
    Future<T> Function() transition,
  ) {
    return runConnectionTransition(() async {
      _intentionalReloadInProgress = true;
      try {
        return await transition();
      } finally {
        _intentionalReloadInProgress = false;
      }
    });
  }

  Future<String?> detectExitCountryForProxy(String proxyName) async {
    try {
      final encoded = Uri.encodeComponent(proxyName);
      final url = 'http://127.0.0.1:${settings.apiPort}/proxies/$encoded/delay';
      final client = apiClient;
      if (client == null) return null;
      final response = await client
          .get(Uri.parse(url), headers: apiHeaders())
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final geo = data['geo'] as String?;
        if (geo != null && geo.isNotEmpty) return geo;
      }
    } catch (_) {}

    try {
      final local = _androidLocalCountryCode(proxyName);
      if (local != null) return local;
    } catch (_) {}

    return null;
  }

  static String flagEmoji(String countryCode) => _androidFlagEmoji(countryCode);

  Future<void> invalidateIdleNativeConnectionSnapshot() =>
      _invalidateIdleNativeConnectionSnapshot();

  void _markNativeConnectionLost() => markConnectionLost();
  void _notifyNativeRuntimeNotice(RuntimeNotice notice) =>
      notifyRuntimeNotice(notice);

  /// External reachability is advisory after the native local VPN gates pass.
  /// It deliberately does not delay the connected state or own the VPN
  /// lifecycle.
  void scheduleUserConnectivityObservation({bool rerunIfActive = false}) =>
      scheduleDataPlaneObservation(rerunIfActive: rerunIfActive);

  @override
  Future<void> observeDataPlaneHealth() async {
    final connectionGeneration = captureAutomaticRestartIntent();
    if (connectionGeneration == null) return;
    final startGeneration = _startGeneration;
    await verifyUserConnectivity(
      shouldContinue: () =>
          isRunning &&
          isDataPlaneObservationCurrent &&
          startGeneration == _startGeneration &&
          isConnectionIntentCurrent(connectionGeneration, connected: true),
    );
  }

  // The native VPN service owns the authoritative 3-second Bridge monitor and
  // tears down the TUN fd when the core exits, including while Flutter sleeps.
  @override
  bool get enablePeriodicHealthMonitor => false;

  @override
  Future<bool> diagnosticCoreAvailable() async =>
      _corePath.isNotEmpty &&
      await FileSystemEntity.type(_corePath, followLinks: false) ==
          FileSystemEntityType.file;

  @override
  String get diagnosticConfigPath => _runningConfigPath ?? configPath;

  @override
  bool get diagnosticConfigRequired => isRunning;

  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async =>
      _androidPlatformDiagnosticChecks();

  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(
        success: false,
        message: 'Android 诊断仅提供只读状态，不执行自动修复。',
      );

  // ── onStopRequired ──

  @override
  Future<void> onStopRequired() => stop();

  @override
  void dispose() {
    _nativeStateEpoch++;
    _nativeStateReconciliationTimer?.cancel();
    _nativeStateReconciliationTimer = null;
    super.dispose();
  }

  @override
  Future<bool> recoverAfterHealthCheckFailure(int connectionGeneration) =>
      _recoverNativeAfterHealthCheckFailure(connectionGeneration);

  // ── 平台调试日志 ──

  @override
  void debugLog(String message) => AppLogger.info('Clash', message);

  @override
  void updateSettings(AppSettings settings) {
    if (apiClient == null) {
      initHttpClient();
    }
    super.updateSettings(settings);
  }

  @override
  Future<bool> canReuseOccupiedApiPort(AppSettings preferred) =>
      _canReuseIdleNativeControllerPort(preferred);
  // ── 初始化 ──
  Future<void> init(AppSettings settings) async {
    updateSettings(settings);

    final appDir = await getApplicationDocumentsDirectory();
    final configDir = '${appDir.path}/ssrvpn';
    final configPath = '$configDir/config.yaml';
    await Directory(configDir).create(recursive: true);
    await Directory('$configDir/providers').create(recursive: true);

    _nativeLibDir = await _getNativeLibraryDir();
    _corePath = '$_nativeLibDir/libgojni.so';

    setPaths(configDir: configDir, configPath: configPath);
    initHttpClient();

    log('原生库目录已解析');
    log('核心文件路径已解析');
    log('配置目录已准备');

    _channel.setMethodCallHandler(_handleNativeMethodCall);

    final coreFile = File(_corePath);
    if (await coreFile.exists()) {
      final size = await coreFile.length();
      log('✅ 核心文件存在: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
    } else {
      log('❌ 核心文件不存在');
      await _debugListDirs();
    }

    await _ensureMMDB();
    await _syncNativeState();
    await resumePendingNativeSnapshotCleanup();
  }

  Future<void> _debugListDirs() async {
    log('--- 核心文件诊断 ---');
    if (_nativeLibDir.isNotEmpty) {
      final dir = Directory(_nativeLibDir);
      if (await dir.exists()) {
        var entryCount = 0;
        await for (final _ in dir.list()) {
          entryCount++;
        }
        log('原生库目录可访问，条目数: $entryCount');
      } else {
        log('原生库目录不存在');
      }
    }
    try {
      final dataApp = Directory('/data/app');
      if (await dataApp.exists()) {
        var matchingDirectoryCount = 0;
        await for (final entity in dataApp.list()) {
          if (entity.path.contains('ssrvpn')) {
            matchingDirectoryCount++;
          }
        }
        log('SSRVPN 安装目录匹配数: $matchingDirectoryCount');
      }
    } catch (e) {
      log('Android 安装目录检查失败: cause=${_safeLogErrorCode(e)}');
    }
  }

  // ── MMDB ──

  Future<void> _ensureMMDB() async {
    final metadbPath = '$configDir/geoip.metadb';
    try {
      await Directory(configDir).create(recursive: true);
      final data = await rootBundle.load('assets/geoip.metadb.gz');
      final compressed = data.buffer.asUint8List();
      final assetRevision = crypto.sha256.convert(compressed).toString();
      final marker = File('$metadbPath.rev');
      final metadb = File(metadbPath);

      if (await metadb.exists() &&
          await metadb.length() > 1024 * 1024 &&
          await marker.exists() &&
          (await marker.readAsString()) == assetRevision) {
        log('✅ MMDB 已存在');
        return;
      }

      final bytes = await Isolate.run(() => gzip.decode(compressed));
      final temp = File('$metadbPath.tmp');
      await temp.writeAsBytes(bytes);
      await temp.rename(metadb.path);
      await marker.writeAsString(assetRevision, flush: true);
      log(
        '✅ MMDB 已从内置资源解压 (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
    } catch (e) {
      log('⚠️ 内置资源复制失败: cause=${_safeLogErrorCode(e)}');
      log('❌ IP 归属数据库不可用；纯 IP 流量无法按地区识别，未命中规则时按默认直连');
    }
  }

  // ── 配置生成 ──

  String generateClashConfig(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) {
    return buildClashConfig(
      rawYaml,
      settings,
      preferredNodeName: preferredNodeName,
      platformHeader: '# ===== SSRVPN Android =====',
      tunConfig: _androidTunConfig(settings),
      latencyTestUrl: settings.latencyTestUrl,
      extraRulesBeforeDirect: _androidForcedProxyAppRules,
    );
  }

  Future<String> generateClashConfigAsync(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) {
    return buildClashConfigAsync(
      rawYaml,
      settings,
      preferredNodeName: preferredNodeName,
      platformHeader: '# ===== SSRVPN Android =====',
      tunConfig: _androidTunConfig(settings),
      latencyTestUrl: settings.latencyTestUrl,
      extraRulesBeforeDirect: _androidForcedProxyAppRules,
    );
  }

  Future<String> writeConfig(String config) => _writeConfigSnapshot(config);

  Future<String> writePreferredNodeConfig(
    String rawYaml,
    AppSettings settings,
    String nodeName, {
    bool Function()? shouldContinue,
    int? expectedSessionGeneration,
  }) async {
    updateSettings(settings);
    final config = await generateClashConfigAsync(
      rawYaml,
      settings,
      preferredNodeName: nodeName,
    );
    final path = await writeConfig(config);
    if (shouldContinue?.call() == false) {
      await discardPreparedConfig(path);
      throw StateError('节点切换已取消');
    }
    if (!await _saveConfigForTile(
      nodeName,
      path,
      shouldContinue: shouldContinue,
      expectedSessionGeneration: expectedSessionGeneration,
    )) {
      await discardPreparedConfig(path);
      throw StateError('无法提交原生快速启动配置');
    }
    return path;
  }

  // ── 进程控制 ──

  @override
  Future<bool> start({String? nodeName, String? preparedConfigPath}) =>
      _start(nodeName: nodeName, preparedConfigPath: preparedConfigPath);

  Future<bool> _start({
    String? nodeName,
    String? preparedConfigPath,
    bool automaticRecovery = false,
  }) {
    if (!automaticRecovery) _healthRecoveryPolicy.reset();
    final current = _startOperation;
    if (current != null) return current;

    final startToken = ++_startGeneration;
    final operation = _startInternal(
      nodeName: nodeName,
      startConfigPath: preparedConfigPath ?? configPath,
      startToken: startToken,
    );
    _startOperation = operation;
    operation.then<void>(
      (_) => _clearStartOperation(operation),
      onError: (_, __) => _clearStartOperation(operation),
    );
    return operation;
  }

  Future<bool> _startInternal({
    String? nodeName,
    required String startConfigPath,
    required int startToken,
  }) async {
    final stopping = _stopOperation;
    if (stopping != null) await stopping;
    _ensureStartCurrent(startToken);
    setLastStartError(null);
    if (isRunning) {
      try {
        if (await healthCheck()) return true;
      } catch (_) {}
      setRunning(false);
      stopStatusMonitor();
    }

    try {
      log('🚀 启动 Mihomo (gomobile)...');
      log('配置文件准备完成');

      if (!File(startConfigPath).existsSync()) {
        log('❌ 配置文件不存在');
        setLastStartError('找不到生成的 VPN 配置文件');
        return false;
      }

      await Directory('$configDir/tmp').create(recursive: true);
      _ensureStartCurrent(startToken);

      // Android owns the VPN permission flow. Keep this Future pending until
      // the user answers instead of imposing a Dart-side deadline.
      final result = await _channel.invokeMethod<Object?>('startCoreWithVpn', {
        'configDir': configDir,
        'configPath': startConfigPath,
        'apiPort': settings.apiPort,
        'apiSecret': runtimeApiSecret,
        'nodeName': nodeName,
      });
      _ensureStartCurrent(startToken);

      final returnedState = await _parseNativeConnectionState(result);
      if (!_acceptNativeStartState(result, returnedState)) {
        return _rollbackMalformedNativeStartState();
      }
      if (result == true || returnedState?.running == true) {
        setRunning(true);
        _nativeConnectionTransitioning = returnedState?.transitioning ?? false;
        if (returnedState == null) {
          _runningConfigPath = startConfigPath;
          _nativeSessionGeneration = null;
        } else {
          _nativeSessionProtocolAvailable = true;
          _runningConfigPath = returnedState.protectedConfigPath;
          _nativeSessionGeneration = returnedState.sessionGeneration;
          _underlyingNetworkAvailable =
              returnedState.underlyingNetworkAvailable;
          _underlyingNetworkValidated =
              returnedState.underlyingNetworkValidated;
        }
        log('✅ Mihomo 启动成功 (gomobile)');
        notifyStatusChanged();
        await _notifyNativeStateChange();
        _ensureStartCurrent(startToken);
        final snapshotSaved = await _saveConfigForTile(
          nodeName,
          startConfigPath,
          shouldContinue: () => startToken == _startGeneration,
        );
        _ensureStartCurrent(startToken);
        if (!snapshotSaved) {
          const snapshotError = '无法保存连接恢复信息，VPN 已安全回滚';
          try {
            await stop();
            setLastStartError(snapshotError);
          } catch (stopError) {
            log('VPN 安全回滚未完整结束: cause=${_safeLogErrorCode(stopError)}');
            setLastStartError('$snapshotError；请重新打开应用后重试');
          }
          return false;
        }
        startStatusMonitor();
        return true;
      } else {
        log('❌ VPN 核心启动结果未确认');
        setLastStartError('VPN 核心未能确认启动，请重试；若持续失败请打开诊断与运行日志');
        return false;
      }
    } on _AndroidStartCancelled {
      setLastStartError('连接已取消');
      log('连接已取消');
      return false;
    } on PlatformException catch (e) {
      if (startToken != _startGeneration) {
        setLastStartError('连接已取消');
        log('连接已取消');
        return false;
      }
      final nativeCategory = _nativeCoreStartFailureCategories[e.code];
      if (nativeCategory != null) {
        log('❌ VPN 核心启动失败: cause=$nativeCategory');
      } else {
        log('❌ VPN 核心启动失败，正在生成可操作提示');
      }
      if (e.code == 'PERMISSION_DENIED') {
        log('⚠️ 用户拒绝了 VPN 权限');
        setLastStartError('用户拒绝了 VPN 权限');
      } else {
        setLastStartError(_nativeStartFailureMessage(e));
      }
      return false;
    } catch (e) {
      log('❌ VPN 核心启动异常: cause=${_safeLogErrorCode(e)}');
      setLastStartError(safeUserFacingFailureMessage(e));
      return false;
    }
  }

  @override
  Future<void> stop() {
    _startGeneration++;
    final current = _stopOperation;
    if (current != null) return current;

    final operation = _stopInternal();
    _stopOperation = operation;
    operation.then<void>(
      (_) => _clearStopOperation(operation),
      onError: (_, __) => _clearStopOperation(operation),
    );
    return operation;
  }

  Future<void> _stopInternal() async {
    stopStatusMonitor();
    resetHealthCheckFailures();

    Object? stopError;
    try {
      await _channel
          .invokeMethod('stopCore')
          .timeout(const Duration(seconds: 15));
      log('核心已停止');
    } catch (e) {
      stopError = e;
      log('停止 VPN 核心失败: cause=${_safeLogErrorCode(e)}');
    }

    final runningAfterStop = stopError == null
        ? false
        : (await _queryNativeRunningState() ?? isRunning);
    setRunning(runningAfterStop);
    if (!runningAfterStop) {
      _nativeConnectionTransitioning = false;
      _underlyingNetworkAvailable = null;
      _underlyingNetworkValidated = null;
      _runningConfigPath = null;
      await _completePendingSnapshotFileCleanup();
      if (_nativeSnapshotOperationCount == 0) {
        await resumePendingNativeSnapshotCleanup();
      }
    }
    if (runningAfterStop) startStatusMonitor();
    notifyStatusChanged();
    await _notifyNativeStateChange();
    if (runningAfterStop) {
      throw StateError('VPN 核心仍在运行，请重试断开');
    }
  }

  Future<bool> _saveConfigForTile(
    String? nodeName,
    String snapshotPath, {
    bool Function()? shouldContinue,
    int? expectedSessionGeneration,
  }) async {
    if (shouldContinue?.call() == false) return false;
    final effectiveSessionGeneration =
        expectedSessionGeneration ?? _nativeSessionGeneration;
    final protectedConfigPathAtStart = _runningConfigPath;
    final protocolAvailableAtStart = _nativeSessionProtocolAvailable;
    if (protocolAvailableAtStart &&
        isRunning &&
        effectiveSessionGeneration == null) {
      log('原生 VPN 会话身份未知，拒绝覆盖快速启动快照');
      return false;
    }
    try {
      return await _serializeNativeSnapshotOperation(() async {
        if (shouldContinue?.call() == false) return false;
        await _preparePendingSnapshotCleanupForReplacement(snapshotPath);
        if (shouldContinue?.call() == false) return false;
        final generation = await _channel.invokeMethod<String>('syncSettings', {
          'configDir': configDir,
          'configPath': snapshotPath,
          'apiPort': settings.apiPort,
          'proxyPort': settings.proxyPort,
          'socksPort': settings.socksPort,
          'apiSecret': runtimeApiSecret,
          'selectedNodeName': nodeName,
          'expectedSessionGeneration': effectiveSessionGeneration,
        });
        if (generation == null || generation.isEmpty) {
          throw StateError('原生快速启动快照未返回有效代际');
        }
        _nativeSnapshotConfigPath = snapshotPath;
        _nativeSnapshotGeneration = generation;
        _preparedConfigPaths.remove(File(snapshotPath).absolute.path);
        try {
          await _reconcileSnapshotCleanupAfterCommit(snapshotPath);
        } catch (error) {
          // syncSettings is the commit point. Reporting failure from here
          // would let the caller delete a config the native snapshot uses.
          // The prepared marker is generation-bound or records the replacement
          // baseline, so recovery cannot clear this newer snapshot.
          log(
            '原生快速启动快照已提交，旧清理事务收口失败: '
            'cause=${_safeLogErrorCode(error)}',
          );
        }

        // The native atomic snapshot is the commit point. Everything below is
        // best-effort but remains under the same serialization tail so an older
        // prune can never race and delete a newer committed snapshot.
        try {
          final prefs = await SharedPreferences.getInstance();
          for (final key in [
            'configDir',
            'configPath',
            'apiPort',
            'apiSecret',
            'selectedNodeName',
          ]) {
            await prefs.remove(key);
          }
          final keepPaths = <String>{snapshotPath};
          keepPaths.addAll(_preparedConfigPaths);
          final runningConfigPath = _runningConfigPath;
          if (runningConfigPath != null) keepPaths.add(runningConfigPath);
          if (protectedConfigPathAtStart != null) {
            keepPaths.add(protectedConfigPathAtStart);
          }
          final nativeSnapshotConfigPath = _nativeSnapshotConfigPath;
          if (nativeSnapshotConfigPath != null) {
            keepPaths.add(nativeSnapshotConfigPath);
          }
          final postCommitState = protocolAvailableAtStart
              ? await _queryNativeConnectionState()
              : null;
          final postCommitProtectedPath = postCommitState?.protectedConfigPath;
          if (postCommitProtectedPath != null) {
            keepPaths.add(postCommitProtectedPath);
          }
          final sessionStable = !protocolAvailableAtStart
              ? !isRunning
              : effectiveSessionGeneration == null
                  ? postCommitState != null &&
                      !postCommitState.running &&
                      !postCommitState.transitioning &&
                      postCommitProtectedPath == null
                  : postCommitState?.running == true &&
                      postCommitState?.sessionGeneration ==
                          effectiveSessionGeneration &&
                      postCommitProtectedPath != null;
          final cleanupSafe = _isNativeConfigPruningSafe(
            sessionStable: sessionStable,
            protocolAvailable: protocolAvailableAtStart,
            nativeState: postCommitState,
          );
          if (!cleanupSafe) {
            log('原生 VPN 会话已变更或正在恢复，保留旧版本配置');
          } else {
            await _pruneVersionedConfigs(keepPaths);
          }
        } catch (error) {
          log(
            '原生快速启动快照已提交，旧数据清理失败: '
            'cause=${_safeLogErrorCode(error)}',
          );
        }
        if (!isRunning) await _completePendingSnapshotFileCleanup();
        return true;
      });
    } catch (error) {
      log(
        '原生快速启动数据同步失败，保留上次可用快照: '
        'cause=${_safeLogErrorCode(error)}',
      );
      return false;
    }
  }

  @override
  Future<bool> switchSelectedProxy(
    String nodeName, {
    SwitchContextGuard? isSwitchContextCurrent,
  }) async {
    final result = await switchSelectedProxyWithSnapshot(
      nodeName,
      isSwitchContextCurrent: isSwitchContextCurrent,
    );
    return result.liveSwitched;
  }

  Future<AndroidProxySwitchResult> switchSelectedProxyWithSnapshot(
    String nodeName, {
    SwitchContextGuard? isSwitchContextCurrent,
  }) async {
    final switched = await super.switchSelectedProxy(
      nodeName,
      isSwitchContextCurrent: isSwitchContextCurrent,
    );
    if (!switched) {
      return const AndroidProxySwitchResult(
        liveSwitched: false,
        snapshotPersisted: false,
        intentCurrent: true,
      );
    }
    if (isSwitchContextCurrent != null && !await isSwitchContextCurrent()) {
      return const AndroidProxySwitchResult(
        liveSwitched: true,
        snapshotPersisted: false,
        intentCurrent: false,
      );
    }
    final persisted = await updateVpnNotification(nodeName);
    return AndroidProxySwitchResult(
      liveSwitched: true,
      snapshotPersisted: persisted,
      intentCurrent: true,
    );
  }

  /// Initial/reload connection flows use this variant so an obsolete intent
  /// cannot publish its node after a newer connect/disconnect request wins.
  Future<AndroidProxySwitchResult> switchSelectedProxyForConnection(
    String nodeName, {
    required int connectionGeneration,
  }) async {
    if (!isConnectionIntentCurrent(connectionGeneration, connected: true)) {
      return const AndroidProxySwitchResult(
        liveSwitched: false,
        snapshotPersisted: false,
        intentCurrent: false,
      );
    }
    if (!await _ensureNativeSessionForMutation()) {
      return const AndroidProxySwitchResult(
        liveSwitched: false,
        snapshotPersisted: false,
        intentCurrent: true,
      );
    }
    final nativeSessionGeneration = _nativeSessionGeneration;
    if (nativeSessionGeneration == null) {
      return const AndroidProxySwitchResult(
        liveSwitched: false,
        snapshotPersisted: false,
        intentCurrent: false,
      );
    }
    final switched = await super.switchSelectedProxy(
      nodeName,
      isSwitchContextCurrent: () async {
        final nativeSessionCurrent = await _isNativeSessionCurrent(
          nativeSessionGeneration,
        );
        return nativeSessionCurrent &&
            isConnectionIntentCurrent(
              connectionGeneration,
              connected: true,
            );
      },
    );
    final intentCurrent = isConnectionIntentCurrent(
      connectionGeneration,
      connected: true,
    );
    if (!intentCurrent) {
      return AndroidProxySwitchResult(
        liveSwitched: switched,
        snapshotPersisted: false,
        intentCurrent: false,
        nativeSessionGeneration: nativeSessionGeneration,
      );
    }
    if (!switched) {
      final runtimeNodeName = await currentSelectedProxyName();
      final nativeSessionCurrent = await _isNativeSessionCurrent(
        nativeSessionGeneration,
      );
      final failureStillCurrent = nativeSessionCurrent &&
          isConnectionIntentCurrent(connectionGeneration, connected: true);
      return AndroidProxySwitchResult(
        liveSwitched: false,
        snapshotPersisted: false,
        intentCurrent: failureStillCurrent,
        nativeSessionGeneration: nativeSessionGeneration,
        runtimeNodeName: failureStillCurrent ? runtimeNodeName : null,
      );
    }
    final updated = await updateVpnNotification(
      nodeName,
      persistSelection: false,
      expectedSessionGeneration: nativeSessionGeneration,
      shouldContinue: () =>
          isConnectionIntentCurrent(connectionGeneration, connected: true),
    );
    final nativeSessionCurrent = await _isNativeSessionCurrent(
      nativeSessionGeneration,
    );
    return AndroidProxySwitchResult(
      liveSwitched: true,
      snapshotPersisted: updated,
      intentCurrent: nativeSessionCurrent &&
          isConnectionIntentCurrent(connectionGeneration, connected: true),
      nativeSessionGeneration: nativeSessionGeneration,
    );
  }

  Future<bool> updateVpnNotification(
    String nodeName, {
    bool persistSelection = true,
    bool Function()? shouldContinue,
    int? expectedSessionGeneration,
  }) async {
    try {
      if (shouldContinue?.call() == false) return false;
      expectedSessionGeneration ??= _nativeSessionGeneration;
      if (_nativeSessionProtocolAvailable &&
          expectedSessionGeneration == null) {
        return false;
      }
      await _channel.invokeMethod('updateVpnNotification', {
        'nodeName': nodeName,
        'expectedSessionGeneration': expectedSessionGeneration,
      });
      if (!persistSelection || shouldContinue?.call() == false) return true;
      final prefs = await SharedPreferences.getInstance();
      if (shouldContinue?.call() == false) return false;
      await prefs.setString('selectedNodeName', nodeName);
      return true;
    } catch (e) {
      log('更新 VPN 通知失败: cause=${_safeLogErrorCode(e)}');
      return false;
    }
  }
}
