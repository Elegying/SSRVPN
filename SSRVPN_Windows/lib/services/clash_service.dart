import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show protected, visibleForTesting;
import 'package:ssrvpn_shared/runtime_notice.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../services/system_proxy_service.dart';
import '../services/windows_tun_elevation_service.dart';
import '../services/windows_tun_runtime_probe.dart';
import '../services/windows_start_transaction.dart';
import '../services/windows_version_provider.dart';
import '../src/services/windows_core_pid_record.dart';
import '../src/services/windows_powershell.dart';

part 'clash_service_config.dart';
part 'clash_service_diagnostics.dart';
part 'clash_service_recovery_policy.dart';
part 'clash_service_lifecycle.dart';
part 'clash_service_start_preparation.dart';
part 'clash_service_tun_recovery.dart';

const List<String> _geoLookupHosts = [
  'api.country.is',
  'ipinfo.io',
  'ifconfig.co',
];

/// Clash Meta 核心管理服务 (Windows 版)
///
/// 通过 spawn mihomo.exe 子进程启动核心，使用 REST API 控制。
/// 支持 TUN 模式（需管理员权限）和系统代理模式。
class ClashService extends ClashServiceBase
    with PhysicalTcpLatency, _WindowsClashConfig, _WindowsCoreLifecycle {
  ClashService({
    WindowsTunRuntimeProbe? tunRuntimeProbe,
    WindowsTunResidualProbe? tunResidualProbe,
    WindowsNetworkInterfaceIdentityProbe? networkInterfaceIdentityProbe,
    WindowsTunElevationService? tunElevationService,
    @visibleForTesting SystemProxyService? systemProxyService,
  }) {
    _proxyService = systemProxyService ?? SystemProxyService();
    _tunRuntimeProbeOverride = tunRuntimeProbe;
    _tunResidualProbeOverride = tunResidualProbe;
    _networkInterfaceIdentityProbeOverride = networkInterfaceIdentityProbe;
    _tunElevationService = tunElevationService ?? WindowsTunElevationService();
  }

  @override
  bool consumeTunElevationRelaunchRequest() {
    final pending = _tunElevationRelaunchPending;
    _tunElevationRelaunchPending = false;
    return pending;
  }

  // ── File logging ──
  File? _logFile;
  BoundedFileLogger? _fileLogger;

  String get logPath => _logFile?.path ?? '';

  Future<void> flushLogs() async => _fileLogger?.flush();

  @override
  void debugLog(String message) {
    AppLogger.info('Clash', message);
  }

  @override
  void updateSettings(AppSettings settings) {
    if (apiClient == null) {
      initHttpClient();
    }
    super.updateSettings(settings);
  }

  @override
  void writePlatformLog(String line) {
    final fileLogger = _fileLogger;
    if (fileLogger != null) {
      fileLogger.add('$line\r\n');
    }
  }

  /// 初始化服务
  Future<void> init(
    AppSettings settings, {
    String? dataDir,
    String? storageNotice,
    bool skipCoreProbes = false,
  }) async {
    super.updateSettings(settings);
    initHttpClient();
    _startupDisabledReason = null;

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final dir = dataDir ?? '$exeDir${Platform.pathSeparator}ssrvpn';
    setPaths(
      configDir: dir,
      configPath: '$dir${Platform.pathSeparator}config.yaml',
    );
    _corePath = '$exeDir${Platform.pathSeparator}mihomo.exe';
    await Directory(configDir).create(recursive: true);
    await _restoreTunTeardownGate();
    await Directory(
      '$configDir${Platform.pathSeparator}providers',
    ).create(recursive: true);
    await ensureBundledSmartRules();
    _logFile = File('$configDir${Platform.pathSeparator}ssrvpn.log');
    await _rotateLogFile();
    _fileLogger = BoundedFileLogger(_logFile!);
    await _proxyService.initialize(configDir);
    if (!skipCoreProbes) {
      await _terminateOrphanedCores();
    }

    log('系统: ${await WindowsVersionProvider().describe()}');
    log('程序路径: ${Platform.resolvedExecutable}');
    log('配置目录: $configDir');
    log('核心路径: $_corePath');
    log('诊断日志: ${_logFile!.path}');
    if (storageNotice != null && storageNotice.isNotEmpty) {
      log('⚠️ $storageNotice');
    }
    if (_proxyService.lastError != null) {
      log('⚠️ ${_proxyService.lastError}');
    }

    // 验证核心文件
    final coreFile = File(_corePath);
    if (await coreFile.exists()) {
      final size = await coreFile.length();
      log('✅ 核心文件存在: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
      if (!skipCoreProbes) {
        await logCoreVersion();
      }
    } else {
      log('❌ 核心文件不存在: $_corePath');
      log('请将 mihomo.exe 放到应用目录下');
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

  /// 预下载 MMDB 文件
  Future<void> _ensureMMDB() async {
    final metadbPath = '$configDir${Platform.pathSeparator}geoip.metadb';

    // 从内置资源复制（gzip 压缩）
    try {
      await Directory(configDir).create(recursive: true);
      final assetPath =
          '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}assets${Platform.pathSeparator}geoip.metadb.gz';
      final compressed = await File(assetPath).readAsBytes();
      final assetRevision = crypto.sha256.convert(compressed).toString();
      final marker = File('$metadbPath.rev');
      final file = File(metadbPath);

      if (await file.exists() &&
          await file.length() > 1024 * 1024 &&
          await marker.exists() &&
          (await marker.readAsString()) == assetRevision) {
        log('✅ MMDB 已存在');
        return;
      }

      final bytes = gzip.decode(compressed);
      final temp = File('$metadbPath.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
      await marker.writeAsString(assetRevision, flush: true);
      log(
        '✅ MMDB 已从内置资源解压 (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
    } catch (e) {
      log('⚠️ MMDB 资源复制失败: $e');
      log('❌ IP 归属数据库不可用；纯 IP 流量无法按地区识别，未命中规则时按默认代理');
    }
  }

  /// 写入配置
  @override
  Future<void> writeDesktopRecoveryConfig(String configContent) =>
      writeConfig(configContent);

  Future<void> writeConfig(String configContent) async {
    if (_startupDisabledReason != null) {
      throw StateError(_startupDisabledReason!);
    }
    if (configPath.isEmpty) {
      throw StateError('连接服务尚未初始化，请重启 SSRVPN；若仍失败，请重新安装官方版本');
    }
    final file = File(configPath);
    final temp = File('$configPath.tmp');
    await temp.writeAsString(configContent);
    await temp.rename(file.path);
  }
}
