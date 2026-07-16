import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ssrvpn_shared/runtime_notice.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../services/system_proxy_service.dart';
import '../services/windows_tun_runtime_probe.dart';
import '../src/services/windows_powershell.dart';

part 'clash_service_config.dart';
part 'clash_service_lifecycle.dart';

const String _geoProxyGroupName = 'SSRVPN-GEO';
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
    with _WindowsClashConfig, _WindowsCoreLifecycle {
  ClashService({
    WindowsTunRuntimeProbe? tunRuntimeProbe,
    WindowsTunResidualProbe? tunResidualProbe,
  }) {
    _tunRuntimeProbeOverride = tunRuntimeProbe;
    _tunResidualProbeOverride = tunResidualProbe;
  }

  // ── File logging ──
  File? _logFile;
  BoundedFileLogger? _fileLogger;

  String get logPath => _logFile?.path ?? '';

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
  void log(String message) {
    super.log(message);
    final fileLogger = _fileLogger;
    if (fileLogger != null) {
      final sanitized = LogRedactor.sanitize(message);
      final line = '[${DateTime.now().toIso8601String()}] $sanitized\r\n';
      fileLogger.add(line);
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
    _logFile = File('$configDir${Platform.pathSeparator}ssrvpn.log');
    await _rotateLogFile();
    _fileLogger = BoundedFileLogger(_logFile!);
    await _proxyService.initialize(configDir);
    if (!skipCoreProbes) {
      await _terminateOrphanedCores();
    }

    log('系统: ${Platform.operatingSystemVersion}');
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
        await _logCoreVersion();
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
      log('❌ MMDB 不可用，GEOIP 规则将跳过');
    }
  }

  /// 写入配置
  Future<void> writeConfig(String configContent) async {
    if (_startupDisabledReason != null) {
      throw StateError(_startupDisabledReason!);
    }
    if (configPath.isEmpty) {
      throw StateError('Mihomo service is not initialized');
    }
    final file = File(configPath);
    final temp = File('$configPath.tmp');
    await temp.writeAsString(configContent);
    await temp.rename(file.path);
  }

  // ── Clash API URL (redefined since base._apiUrl is library-private) ──

  String _apiUrl(String path) {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return 'http://127.0.0.1:${settings.apiPort}/$cleanPath';
  }

  // ── Geo / exit country detection (Windows-specific) ──

  /// 测试延迟 (TCP 连接)
  Future<String?> detectExitCountryForProxy(
    String nodeName, {
    Duration timeout = const Duration(seconds: 7),
  }) async {
    if (!isRunning || nodeName.trim().isEmpty) return null;

    final groupName =
        settings.proxyMode == ProxyMode.global ? 'GLOBAL' : _geoProxyGroupName;
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
      final client = apiClient;
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
    } catch (_) {}
    return null;
  }

  Future<bool> _switchProxyGroup(String groupName, String nodeName) async {
    try {
      final client = apiClient;
      if (client == null) return false;
      final url = _apiUrl('/proxies/${Uri.encodeComponent(groupName)}');
      log('切换代理: group=$groupName, node=$nodeName');
      log('API URL: $url');

      final response = await client
          .put(
            Uri.parse(url),
            headers: apiHeaders(json: true),
            body: jsonEncode({'name': nodeName}),
          )
          .timeout(const Duration(seconds: 5));

      log('API 响应: ${response.statusCode} ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 204) {
        log('✅ 代理切换成功: $nodeName');
        return true;
      }
      log('❌ 代理切换失败: HTTP ${response.statusCode}');
      return false;
    } catch (e) {
      log('❌ 切换代理异常: $e');
      return false;
    }
  }

  Future<String?> _queryExitCountry({required Duration timeout}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..findProxy = (_) => 'PROXY 127.0.0.1:${settings.proxyPort}';
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
    final plain = normalizeCountryCode(text);
    if (plain != null) return plain;

    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        for (final key in const ['country', 'countryCode', 'country_code']) {
          final value = decoded[key]?.toString();
          final code = normalizeCountryCode(value);
          if (code != null) return code;
        }
      }
    } catch (_) {}
    return null;
  }
}
