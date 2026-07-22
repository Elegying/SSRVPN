import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

part 'clash_service_snapshot_cleanup.dart';
part 'clash_service_native_bridge.dart';

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
  final CoreRecoveryPolicy _healthRecoveryPolicy =
      CoreRecoveryPolicy(maxAttempts: 1);
  Future<void> _nativeSnapshotOperationTail = Future<void>.value();
  int _nativeSnapshotOperationCount = 0;
  String? _nativeSnapshotConfigPath;
  String? _nativeSnapshotGeneration;
  int _startGeneration = 0;
  int _configRevision = 0;
  int _nativeStateEpoch = 0;
  int? _nativeSessionGeneration;
  bool _nativeSessionProtocolAvailable = false;
  String? _runningConfigPath;
  final Set<String> _preparedConfigPaths = <String>{};

  /// 磁贴/通知触发的自动连接回调
  VoidCallback? onAutoConnect;

  String get corePath => _corePath;
  bool get coreExists => File(_corePath).existsSync();
  void setCorePath(String path) => _corePath = path;

  Future<void> invalidateIdleNativeConnectionSnapshot() =>
      _invalidateIdleNativeConnectionSnapshot();

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

  // ── onStopRequired ──

  @override
  Future<void> onStopRequired() => stop();

  @override
  Future<bool> recoverAfterHealthCheckFailure(
    int connectionGeneration,
  ) async {
    if (!isConnectionIntentCurrent(connectionGeneration, connected: true)) {
      await stop();
      return false;
    }
    if (await healthCheck()) {
      setRunning(true);
      return true;
    }
    if (!_healthRecoveryPolicy.tryAcquire()) {
      await stop();
      return false;
    }

    final activeConfigPath =
        _runningConfigPath ?? _nativeSnapshotConfigPath ?? configPath;
    notifyRuntimeNotice('Mihomo 持续失去响应，正在执行一次安全重启…');
    try {
      await stop();
    } catch (error) {
      log('健康检查恢复时停止 Mihomo 失败: $error');
      return false;
    }
    if (!isConnectionIntentCurrent(connectionGeneration, connected: true)) {
      return false;
    }
    if (activeConfigPath.isEmpty || !File(activeConfigPath).existsSync()) {
      setLastStartError('自动恢复所需的运行配置已不存在');
      return false;
    }
    return _start(
      preparedConfigPath: activeConfigPath,
      automaticRecovery: true,
    );
  }

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

    log('nativeLibDir: $_nativeLibDir');
    log('核心路径: $_corePath');
    log('配置目录: $configDir');

    _channel.setMethodCallHandler(_handleNativeMethodCall);

    final coreFile = File(_corePath);
    if (await coreFile.exists()) {
      final size = await coreFile.length();
      log('✅ 核心文件存在: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
    } else {
      log('❌ 核心文件不存在: $_corePath');
      await _debugListDirs();
    }

    await _ensureMMDB();
    await _syncNativeState();
    await resumePendingNativeSnapshotCleanup();
  }

  Future<void> _debugListDirs() async {
    log('--- 调试目录 ---');
    if (_nativeLibDir.isNotEmpty) {
      final dir = Directory(_nativeLibDir);
      if (await dir.exists()) {
        log('$_nativeLibDir 内容:');
        await for (final entity in dir.list()) {
          final size = entity is File ? await entity.length() : 0;
          log('  ${entity.path.split('/').last} ($size bytes)');
        }
      } else {
        log('$_nativeLibDir 不存在');
      }
    }
    try {
      final dataApp = Directory('/data/app');
      if (await dataApp.exists()) {
        log('/data/app/ 内容:');
        await for (final entity in dataApp.list()) {
          if (entity.path.contains('ssrvpn')) {
            log('  ${entity.path}');
            if (entity is Directory) {
              await for (final sub in entity.list()) {
                log('    ${sub.path.split('/').last}');
              }
            }
          }
        }
      }
    } catch (e) {
      log('列出 /data/app 失败: $e');
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
      log('✅ MMDB 已从内置资源解压 (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)');
    } catch (e) {
      log('⚠️ 内置资源复制失败: $e');
      log('❌ MMDB 不可用，GEOIP 规则将跳过');
    }
  }

  // ── 配置生成 ──

  bool _geoipDatabaseExists() {
    try {
      final mmdb = File('$configDir/country.mmdb');
      if (mmdb.existsSync() && mmdb.lengthSync() > 1024 * 1024) return true;
      final metadb = File('$configDir/geoip.metadb');
      if (metadb.existsSync() && metadb.lengthSync() > 1024 * 1024) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  String _androidTunConfig(AppSettings settings) {
    final buffer = StringBuffer()
      ..writeln('tun:')
      ..writeln('  enable: true')
      ..writeln('  stack: ${settings.tunStack}')
      ..writeln('  dns-hijack:')
      ..writeln('    - any:53')
      ..writeln('  auto-route: true')
      ..writeln('  auto-detect-interface: true')
      ..writeln('  inet6-address:')
      ..writeln('    - ${AppConstants.tunInet6Address}')
      ..writeln('  route-exclude-address:');
    for (final address in AppConstants.routeExcludeAddresses) {
      // Android 原生 VPN 接管 ::/0；不排除 IPv6，避免绕过或黑洞。
      if (address.contains(':')) continue;
      buffer.writeln('    - $address');
    }
    return buffer.toString().trimRight();
  }

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
      includeGeoIpRules: _geoipDatabaseExists(),
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
      includeGeoIpRules: _geoipDatabaseExists(),
    );
  }

  Future<String> writeConfig(String configContent) async {
    final revision = ++_configRevision;
    final path = '$configDir/config-'
        '${DateTime.now().microsecondsSinceEpoch}-$revision.yaml';
    final absolutePath = File(path).absolute.path;
    _preparedConfigPaths.add(absolutePath);
    try {
      await writeStringAtomically(File(absolutePath), configContent);
      return absolutePath;
    } catch (_) {
      _preparedConfigPaths.remove(absolutePath);
      rethrow;
    }
  }

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

  Future<bool> start({String? nodeName, String? preparedConfigPath}) => _start(
        nodeName: nodeName,
        preparedConfigPath: preparedConfigPath,
      );

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
      log('配置: $startConfigPath');

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
        'apiSecret': settings.apiSecret,
        'nodeName': nodeName,
      });
      _ensureStartCurrent(startToken);

      final returnedState = await _parseNativeConnectionState(result);
      if (result == true || returnedState?.running == true) {
        setRunning(true);
        if (returnedState == null) {
          _runningConfigPath = startConfigPath;
          _nativeSessionGeneration = null;
        } else {
          _nativeSessionProtocolAvailable = true;
          _runningConfigPath = returnedState.protectedConfigPath;
          _nativeSessionGeneration = returnedState.sessionGeneration;
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
          const snapshotError = '无法保存快速启动配置，VPN 已安全回滚';
          try {
            await stop();
            setLastStartError(snapshotError);
          } catch (stopError) {
            setLastStartError('$snapshotError；$stopError');
          }
          return false;
        }
        startStatusMonitor();
        return true;
      } else {
        log('❌ 核心启动失败: $result');
        setLastStartError(result?.toString() ?? '无法启动VPN核心');
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
      log('❌ 启动异常: ${e.message}');
      final msg = e.message ?? '无法启动VPN核心';
      if (e.code == 'PERMISSION_DENIED') {
        log('⚠️ 用户拒绝了 VPN 权限');
        setLastStartError('用户拒绝了 VPN 权限');
      } else {
        setLastStartError(msg);
      }
      return false;
    } catch (e, stack) {
      log('❌ 启动异常: $e');
      log('堆栈: $stack');
      setLastStartError('无法启动VPN核心: $e');
      return false;
    }
  }

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
      log('停止异常: $e');
    }

    final runningAfterStop = stopError == null
        ? false
        : (await _queryNativeRunningState() ?? isRunning);
    setRunning(runningAfterStop);
    if (!runningAfterStop) {
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

  void _clearStartOperation(Future<bool> operation) {
    if (identical(_startOperation, operation)) _startOperation = null;
  }

  void _ensureStartCurrent(int startToken) {
    if (startToken != _startGeneration) throw _AndroidStartCancelled();
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
        final generation = await _channel.invokeMethod<String>(
          'syncSettings',
          {
            'configDir': configDir,
            'configPath': snapshotPath,
            'apiPort': settings.apiPort,
            'proxyPort': settings.proxyPort,
            'apiSecret': settings.apiSecret,
            'selectedNodeName': nodeName,
            'expectedSessionGeneration': effectiveSessionGeneration,
          },
        );
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
          log('原生快速启动快照已提交，旧清理事务收口失败: $error');
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
          if (!sessionStable) {
            log('原生 VPN 会话已变更或正在恢复，保留旧版本配置');
          } else {
            await _pruneVersionedConfigs(keepPaths);
          }
        } catch (error) {
          log('原生快速启动快照已提交，旧数据清理失败: $error');
        }
        if (!isRunning) await _completePendingSnapshotFileCleanup();
        return true;
      });
    } catch (error) {
      log('原生快速启动数据同步失败，保留上次可用快照: $error');
      return false;
    }
  }

  @override
  Future<bool> switchSelectedProxy(String nodeName) async {
    final result = await switchSelectedProxyWithSnapshot(nodeName);
    return result.liveSwitched;
  }

  Future<AndroidProxySwitchResult> switchSelectedProxyWithSnapshot(
    String nodeName,
  ) async {
    final switched = await super.switchSelectedProxy(nodeName);
    if (!switched) {
      return const AndroidProxySwitchResult(
        liveSwitched: false,
        snapshotPersisted: false,
        intentCurrent: true,
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
    final switched = await super.switchSelectedProxy(nodeName);
    final intentCurrent =
        isConnectionIntentCurrent(connectionGeneration, connected: true);
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
      final nativeSessionCurrent =
          await _isNativeSessionCurrent(nativeSessionGeneration);
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
      shouldContinue: () => isConnectionIntentCurrent(
        connectionGeneration,
        connected: true,
      ),
    );
    final nativeSessionCurrent =
        await _isNativeSessionCurrent(nativeSessionGeneration);
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
      log('更新 VPN 通知失败: $e');
      return false;
    }
  }

  // ── 出口国家检测 ──

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
      final local = _getLocalCountryCode(proxyName);
      if (local != null) return local;
    } catch (_) {}

    return null;
  }

  static String? _getLocalCountryCode(String name) {
    final upper = name.toUpperCase().trim();
    final isoMatch = RegExp(r'(?:^|\s|[-/#【\[\(（])'
        r'(US|UK|GB|JP|KR|HK|TW|SG|DE|FR|NL|CA|AU|IN|TH|VN|ID|PH|MY|RU|TR|BR|AR|MX|ZA|IT|ES|SE|NO|FI|DK|IE|CH|AT|BE|PL|UA|CL|CO|PE)'
        r'(?:$|\s|[-/#】\]\)）]|[^A-Z])');
    final match = isoMatch.firstMatch(upper);
    if (match != null) return match.group(1);

    const keywordMap = {
      '美国': 'US',
      '洛杉矶': 'US',
      '圣何塞': 'US',
      '纽约': 'US',
      'USA': 'US',
      'AMERICA': 'US',
      '日本': 'JP',
      '东京': 'JP',
      '大阪': 'JP',
      'JAPAN': 'JP',
      '韩国': 'KR',
      '首尔': 'KR',
      'KOREA': 'KR',
      'SOUTH KOREA': 'KR',
      '香港': 'HK',
      'HONG KONG': 'HK',
      '台湾': 'TW',
      '台北': 'TW',
      'TAIWAN': 'TW',
      '新加坡': 'SG',
      'SINGAPORE': 'SG',
      '德国': 'DE',
      '法兰克福': 'DE',
      'GERMANY': 'DE',
      '法国': 'FR',
      '巴黎': 'FR',
      'FRANCE': 'FR',
      '荷兰': 'NL',
      'NETHERLANDS': 'NL',
      '加拿大': 'CA',
      'CANADA': 'CA',
      '澳大利亚': 'AU',
      '悉尼': 'AU',
      'AUSTRALIA': 'AU',
      '印度': 'IN',
      '孟买': 'IN',
      'INDIA': 'IN',
      '泰国': 'TH',
      '曼谷': 'TH',
      'THAILAND': 'TH',
      '越南': 'VN',
      'VIETNAM': 'VN',
      '印尼': 'ID',
      '雅加达': 'ID',
      '菲律宾': 'PH',
      '马尼拉': 'PH',
      '马来西亚': 'MY',
      '吉隆坡': 'MY',
      'MALAYSIA': 'MY',
      '俄罗斯': 'RU',
      '莫斯科': 'RU',
      'RUSSIA': 'RU',
      '土耳其': 'TR',
      'TURKEY': 'TR',
      '巴西': 'BR',
      'BRAZIL': 'BR',
      '阿根廷': 'AR',
      'ARGENTINA': 'AR',
      '墨西哥': 'MX',
      'MEXICO': 'MX',
      '英国': 'GB',
      '伦敦': 'GB',
      'UNITED KINGDOM': 'GB',
      '意大利': 'IT',
      'ITALY': 'IT',
      '西班牙': 'ES',
      'SPAIN': 'ES',
      '瑞典': 'SE',
      'SWEDEN': 'SE',
      '挪威': 'NO',
      'NORWAY': 'NO',
      '芬兰': 'FI',
      'FINLAND': 'FI',
      '丹麦': 'DK',
      'DENMARK': 'DK',
      '瑞士': 'CH',
      'SWITZERLAND': 'CH',
      '南非': 'ZA',
      'SOUTH AFRICA': 'ZA',
    };
    for (final entry in keywordMap.entries) {
      if (upper.contains(entry.key)) return entry.value;
    }
    return null;
  }

  static String flagEmoji(String countryCode) {
    if (countryCode.length != 2) return '🏳️';
    final first = countryCode.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final second = countryCode.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCodes([first, second]);
  }
}
