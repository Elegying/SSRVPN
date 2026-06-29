import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:yaml/yaml.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/utils/log_redactor.dart';
import 'package:ssrvpn_shared/utils/private_node_latency_policy.dart';
import '../models/app_settings.dart';

/// Clash Meta 核心管理服务 (Android 版)
class ClashService {
  static const _channel = MethodChannel('com.ssrvpn/native');

  Timer? _statusTimer;
  bool _isRunning = false;
  String? _lastStartError;

  AppSettings _settings = AppSettings();
  String _corePath = '';
  String _configDir = '';
  String _configPath = '';
  String _logBuffer = '';
  String _nativeLibDir = '';

  VoidCallback? onStatusChanged;
  void Function(String message)? onLog;

  /// 磁贴/通知触发的自动连接回调
  VoidCallback? onAutoConnect;

  bool get isRunning => _isRunning;
  String get recentLogs => _logBuffer;
  String? get lastStartError => _lastStartError;
  int get runtimeProxyPort => _settings.proxyPort;

  /// 同步最新设置（端口/secret 等变更后必须调用，否则 API 调用仍用旧值）
  void updateSettings(AppSettings settings) {
    _settings = settings;
  }

  /// 查询并消费原生层的"待自动连接"标记（磁贴冷启动场景）
  Future<bool> consumePendingAutoConnect() async {
    try {
      final pending = await _channel.invokeMethod<bool>(
        'consumePendingAutoConnect',
      );
      return pending == true;
    } catch (_) {
      return false;
    }
  }

  /// 初始化服务
  Future<void> init(AppSettings settings) async {
    _settings = settings;

    // 配置目录
    final appDir = await getApplicationDocumentsDirectory();
    _configDir = '${appDir.path}/ssrvpn';
    _configPath = '$_configDir/config.yaml';
    await Directory(_configDir).create(recursive: true);

    // 获取 native library 目录 (通过 MethodChannel)
    _nativeLibDir = await _getNativeLibraryDir();
    _corePath = '$_nativeLibDir/libgojni.so';

    _log('nativeLibDir: $_nativeLibDir');
    _log('核心路径: $_corePath');
    _log('配置目录: $_configDir');

    // 监听原生回调（磁贴/通知触发）
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'autoConnect') {
        _log('收到原生自动连接请求');
        onAutoConnect?.call();
      } else if (call.method == 'vpnStateChanged') {
        // 磁贴等原生入口操作 VPN 后实时同步状态
        final connected = call.arguments == true;
        if (_isRunning != connected) {
          _isRunning = connected;
          _log(connected ? '原生通知: VPN 已连接' : '原生通知: VPN 已断开');
          if (connected) {
            _startStatusMonitor();
          } else {
            _statusTimer?.cancel();
            _statusTimer = null;
          }
          onStatusChanged?.call();
        }
      }
    });

    // 验证核心文件
    final coreFile = File(_corePath);
    if (await coreFile.exists()) {
      final size = await coreFile.length();
      _log('✅ 核心文件存在: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
    } else {
      _log('❌ 核心文件不存在: $_corePath');
      await _debugListDirs();
    }

    // 预下载 MMDB 文件 (避免启动时下载超时)
    await _ensureMMDB();

    // 同步原生 VPN 状态：磁贴可能在 App 未运行时已启动 VPN
    await _syncNativeState();
  }

  /// 查询原生层 VPN 服务是否在运行，同步到 Dart 状态
  Future<void> _syncNativeState() async {
    try {
      final running = await _channel.invokeMethod<bool>('isCoreRunning');
      if (running == true && !_isRunning) {
        _isRunning = true;
        _log('检测到 VPN 已在运行（磁贴启动），同步状态');
        _startStatusMonitor();
      }
    } catch (e) {
      _log('查询原生 VPN 状态失败: $e');
    }
  }

  /// 通过 MethodChannel 获取 Android nativeLibraryDir
  Future<String> _getNativeLibraryDir() async {
    try {
      final result = await _channel.invokeMethod<String>('getNativeLibraryDir');
      if (result != null && result.isNotEmpty) {
        return result;
      }
    } catch (e) {
      _log('MethodChannel getNativeLibraryDir 失败: $e');
    }

    // Fallback: 尝试常见路径
    final candidates = ['/data/app/~~/lib/arm64', '/data/app/lib/arm64'];

    for (final dir in candidates) {
      if (Directory(dir).existsSync()) {
        final entities = Directory(dir).listSync();
        for (final e in entities) {
          if (e.path.contains('libgojni')) return dir;
        }
      }
    }

    return '/data/app/lib/arm64';
  }

  /// 预下载 MMDB 文件
  Future<void> _ensureMMDB() async {
    final mmdbPath = '$_configDir/country.mmdb';
    final metadbPath = '$_configDir/geoip.metadb';

    // 检查是否已存在
    try {
      final m = File(mmdbPath);
      if (await m.exists() && await m.length() > 1024 * 1024) {
        _log('✅ MMDB 已存在');
        return;
      }
      final g = File(metadbPath);
      if (await g.exists() && await g.length() > 1024 * 1024) {
        _log('✅ MMDB 已存在');
        return;
      }
    } catch (_) {}

    // 从内置资源复制（gzip 压缩打包以减小安装体积，首次运行解压释放）
    try {
      await Directory(_configDir).create(recursive: true);
      final data = await rootBundle.load('assets/geoip.metadb.gz');
      final compressed = data.buffer.asUint8List();
      // 解压在后台 isolate 执行，避免首次启动卡住 UI
      final bytes = await Isolate.run(() => gzip.decode(compressed));
      final f = File(metadbPath);
      final temp = File('$metadbPath.tmp');
      await temp.writeAsBytes(bytes);
      await temp.rename(f.path);
      _log(
        '✅ MMDB 已从内置资源解压 (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
      return;
    } catch (e) {
      _log('⚠️ 内置资源复制失败: $e');
    }

    _log('❌ MMDB 不可用，GEOIP 规则将跳过');
  }

  /// 调试: 列出相关目录
  Future<void> _debugListDirs() async {
    _log('--- 调试目录 ---');

    // 列出 nativeLibDir
    if (_nativeLibDir.isNotEmpty) {
      final dir = Directory(_nativeLibDir);
      if (await dir.exists()) {
        _log('$_nativeLibDir 内容:');
        await for (final entity in dir.list()) {
          final size = entity is File ? await entity.length() : 0;
          _log('  ${entity.path.split('/').last} ($size bytes)');
        }
      } else {
        _log('$_nativeLibDir 不存在');
      }
    }

    // 尝试 /data/app/ 下查找
    try {
      final dataApp = Directory('/data/app');
      if (await dataApp.exists()) {
        _log('/data/app/ 内容:');
        await for (final entity in dataApp.list()) {
          if (entity.path.contains('ssrvpn')) {
            _log('  ${entity.path}');
            // 列出子目录
            if (entity is Directory) {
              await for (final sub in entity.list()) {
                _log('    ${sub.path.split('/').last}');
              }
            }
          }
        }
      }
    } catch (e) {
      _log('列出 /data/app 失败: $e');
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

  /// 提取代理名称列表
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
    final hosts = <String>{};
    final rules = <String>[];
    for (final site in settings.forceProxySites) {
      final host = AppSettings.extractForceProxyHost(site);
      if (host == null || !hosts.add(host)) continue;

      final address = InternetAddress.tryParse(host);
      if (address == null) {
        rules.add('DOMAIN-SUFFIX,$host,PROXY');
      } else if (address.type == InternetAddressType.IPv4) {
        rules.add('IP-CIDR,$host/32,PROXY,no-resolve');
      }
    }
    return rules;
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

    // 检查 MMDB 是否存在且有效（>1MB）
    final selectedProxyNames = List<String>.from(proxyNames);
    if (preferredNodeName != null &&
        selectedProxyNames.remove(preferredNodeName)) {
      selectedProxyNames.insert(0, preferredNodeName);
    }

    final mmdbExists = (() {
      try {
        final m = File('$_configDir/country.mmdb');
        if (m.existsSync() && m.lengthSync() > 1024 * 1024) return true;
        final g = File('$_configDir/geoip.metadb');
        if (g.existsSync() && g.lengthSync() > 1024 * 1024) return true;
      } catch (_) {}
      return false;
    })();

    final result = StringBuffer();
    result.writeln('# ===== SSRVPN Android =====');
    result.writeln('mixed-port: ${settings.proxyPort}');
    result.writeln('socks-port: ${settings.socksPort}');
    result.writeln('allow-lan: false');
    result.writeln('mode: ${settings.proxyMode.name}');
    result.writeln('log-level: info');
    result.writeln("external-controller: '127.0.0.1:${settings.apiPort}'");
    result.writeln('# SSRVPN Android 当前明确只支持 IPv4 节点与 IPv4 流量');
    result.writeln('ipv6: false');
    if (settings.apiSecret.isNotEmpty) {
      result.writeln('secret: "${settings.apiSecret}"');
    }

    // TUN — Android 上 VpnService 总是 establish TUN 并把 fd 交给核心，
    // 这里必须恒为 true，否则全局流量被路由进无人读取的 TUN 导致整机断网
    result.writeln();
    result.writeln('tun:');
    result.writeln('  enable: true');
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
    result.writeln("    url: 'http://www.gstatic.com/generate_204'");
    result.writeln('    interval: 300');

    // Rules
    result.writeln();
    result.writeln('rules:');
    for (final rule in _buildForceProxyRules(settings)) {
      result.writeln('  - ${_quote(rule)}');
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
    final file = File(_configPath);
    final temp = File('$_configPath.tmp');
    await temp.writeAsString(configContent);
    await temp.rename(file.path);
  }

  /// 启动核心 (通过 gomobile VPN Service)
  Future<bool> start({String? nodeName}) async {
    _lastStartError = null;
    if (_isRunning) {
      try {
        if (await _healthCheck()) return true;
      } catch (_) {}
      _isRunning = false;
      _statusTimer?.cancel();
    }

    try {
      _log('🚀 启动 Mihomo (gomobile)...');
      _log('配置: $_configPath');

      if (!File(_configPath).existsSync()) {
        _log('❌ 配置文件不存在');
        _lastStartError = '找不到生成的 VPN 配置文件';
        return false;
      }

      // 创建 tmp 目录
      await Directory('$_configDir/tmp').create(recursive: true);

      // 通过原生 VPN Service + gomobile 启动
      final result = await _channel.invokeMethod('startCoreWithVpn', {
        'configDir': _configDir,
        'configPath': _configPath,
        'apiPort': _settings.apiPort,
        'apiSecret': _settings.apiSecret,
        'nodeName': nodeName,
      }).timeout(
        const Duration(seconds: 55),
        onTimeout: () async {
          try {
            await _channel
                .invokeMethod('stopCore')
                .timeout(const Duration(seconds: 5), onTimeout: () => null);
          } catch (_) {}
          _isRunning = false;
          _notifyNativeStateChange();
          throw TimeoutException('设备性能不足，请重新连接');
        },
      );

      if (result == true) {
        _isRunning = true;
        _log('✅ Mihomo 启动成功 (gomobile)');
        onStatusChanged?.call();
        _notifyNativeStateChange();
        _saveConfigForTile(nodeName);
        _startStatusMonitor();
        return true;
      } else {
        _log('❌ 核心启动失败: $result');
        _lastStartError = result?.toString() ?? '无法启动VPN核心';
        return false;
      }
    } on PlatformException catch (e) {
      _log('❌ 启动异常: ${e.message}');
      if (e.code == 'PERMISSION_DENIED') {
        _log('⚠️ 用户拒绝了 VPN 权限');
        _lastStartError = '用户拒绝了 VPN 权限';
      }
      if (e.message == '设备性能不足，请重新连接') {
        _log('⚠️ 设备性能不足，请重新连接');
        _lastStartError = '设备性能不足，请重新连接';
      }
      _lastStartError ??= e.message ?? '无法启动VPN核心';
      return false;
    } on TimeoutException catch (e) {
      _log('❌ ${e.message ?? "设备性能不足，请重新连接"}');
      _lastStartError = e.message ?? '设备性能不足，请重新连接';
      return false;
    } catch (e, stack) {
      _log('❌ 启动异常: $e');
      _log('堆栈: $stack');
      _lastStartError = '无法启动VPN核心: $e';
      return false;
    }
  }

  /// 停止核心
  Future<void> stop() async {
    _statusTimer?.cancel();
    _statusTimer = null;
    _consecutiveFailures = 0;
    _healthCheckClient?.close();
    _healthCheckClient = null;

    try {
      await _channel.invokeMethod('stopCore');
      _log('核心已停止');
    } catch (e) {
      _log('停止异常: $e');
    }

    _isRunning = false;
    onStatusChanged?.call();
    _notifyNativeStateChange();
  }

  /// 通知原生层 VPN 状态变更（用于磁贴/通知同步）
  void _notifyNativeStateChange() {
    try {
      _channel.invokeMethod('notifyVpnStateChanged');
    } catch (_) {}
  }

  /// 保存配置到 SharedPreferences，供磁贴直接启动 VPN
  Future<void> _saveConfigForTile(String? nodeName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('configDir', _configDir);
      await prefs.setString('configPath', _configPath);
      await prefs.setInt('apiPort', _settings.apiPort);
      await prefs.setString('apiSecret', _settings.apiSecret);
      if (nodeName != null && nodeName.isNotEmpty) {
        await prefs.setString('selectedNodeName', nodeName);
      }
    } catch (_) {}
  }

  Future<void> updateVpnNotification(String nodeName) async {
    try {
      await _channel.invokeMethod('updateVpnNotification', {
        'nodeName': nodeName,
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selectedNodeName', nodeName);
    } catch (e) {
      _log('更新 VPN 通知失败: $e');
    }
  }

  http.Client? _healthCheckClient;
  int _consecutiveFailures = 0;
  static const int _maxConsecutiveFailures = 3;

  /// 健康检查（复用 HttpClient，连续 3 次失败才断连）
  Future<bool> _healthCheck() async {
    try {
      _healthCheckClient ??= http.Client();
      final response = await _healthCheckClient!
          .get(
            Uri.parse(_apiUrl('version')),
            headers: _apiHeaders(),
          )
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (e) {
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
    } catch (e) {
      return '已连接，但网络验证失败，请尝试切换节点或刷新订阅';
    } finally {
      client.close();
    }
  }

  String _apiUrl(String path) {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return 'http://127.0.0.1:${_settings.apiPort}/$cleanPath';
  }

  /// Clash API 认证头（secret 非空时附带 Bearer token）
  Map<String, String> _apiHeaders([Map<String, String>? extra]) {
    return {
      if (_settings.apiSecret.isNotEmpty)
        'Authorization': 'Bearer ${_settings.apiSecret}',
      ...?extra,
    };
  }

  /// DNS ping 方式测试延迟 (直接 TCP 连接代理服务器)
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

  /// 批量 ping 测速
  Future<void> testAllLatencies(
    List<ProxyNode> nodes,
    void Function(String name, int latency) onResult, {
    int concurrency = 10,
    int timeoutMs = 5000,
  }) async {
    final random = Random();
    // 分批并发
    for (var i = 0; i < nodes.length; i += concurrency) {
      if (!_isRunning) break; // VPN 断开后停止测速
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
    // 方案A: 事件驱动等待连接数清零，最高兜底 250ms
    await _waitConnectionsClosed(timeoutMs: 250);
    return proxyOk && globalOk;
  }

  /// 方案A: 事件驱动轮询等待活跃连接数降为零（最高兜底 250ms）
  Future<void> _waitConnectionsClosed({int timeoutMs = 250}) async {
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < timeoutMs) {
      final count = await _countActiveConnections();
      if (count <= 0) return;
      await Future.delayed(const Duration(milliseconds: 30));
    }
  }

  /// 查询当前活跃连接数
  Future<int> _countActiveConnections() async {
    try {
      final url = _apiUrl('/connections');
      final response = await http
          .get(Uri.parse(url), headers: _apiHeaders())
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final connections = data['connections'] as List?;
        return connections?.length ?? 0;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }

  /// 检测指定代理的出口国家（通过 Clash API proxy delay / GEOIP）
  /// 返回国家代码 (如 'US', 'JP') 或 null
  Future<String?> detectExitCountryForProxy(String proxyName) async {
    try {
      // 优先用 proxy delay 返回的地理信息
      final url = _apiUrl('/proxies/${Uri.encodeComponent(proxyName)}/delay');
      final response = await http
          .get(
            Uri.parse(url),
            headers: _apiHeaders(),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final geo = data['geo'] as String?;
        if (geo != null && geo.isNotEmpty) return geo;
      }
    } catch (_) {}

    // 备用：通过节点名称本地规则匹配
    try {
      final localModule = _getLocalCountryCode(proxyName);
      if (localModule != null) return localModule;
    } catch (_) {}

    return null;
  }

  /// 从节点名称本地匹配国家代码（使用 [^A-Z] 非 [^A-Z0-9]，修复东京/台湾识别）
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

  /// 国家代码 → 国旗 emoji
  static String flagEmoji(String countryCode) {
    if (countryCode.length != 2) return '🏳️';
    final first = countryCode.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final second = countryCode.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCodes([first, second]);
  }

  Future<bool> _switchProxyGroup(String groupName, String nodeName) async {
    try {
      final url = _apiUrl('/proxies/${Uri.encodeComponent(groupName)}');
      final response = await http
          .put(
            Uri.parse(url),
            headers: _apiHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'name': nodeName}),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200 || response.statusCode == 204) {
        return true;
      }
      return false;
    } catch (e) {
      _log('切换代理失败: $e');
      return false;
    }
  }

  Future<void> _closeConnections() async {
    try {
      await http
          .delete(Uri.parse(_apiUrl('/connections')), headers: _apiHeaders())
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  void _startStatusMonitor() {
    _statusTimer?.cancel();
    _consecutiveFailures = 0;
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_isRunning) return;
      final healthy = await _healthCheck();
      if (healthy) {
        _consecutiveFailures = 0;
      } else {
        _consecutiveFailures++;
        if (_consecutiveFailures >= _maxConsecutiveFailures && _isRunning) {
          _isRunning = false;
          _log('核心连接丢失（连续 $_maxConsecutiveFailures 次健康检查失败）');
          onStatusChanged?.call();
          _notifyNativeStateChange();
          await stop();
        }
      }
    });
  }

  static const bool _kReleaseMode = bool.fromEnvironment('dart.vm.product');

  /// 日志敏感数据过滤
  static String sanitize(String msg) => LogRedactor.sanitize(msg);

  void _log(String message) {
    final sanitized = sanitize(message);
    _logBuffer = '$sanitized\n$_logBuffer';
    if (_logBuffer.length > 10000) _logBuffer = _logBuffer.substring(0, 10000);
    onLog?.call(sanitized);
    if (!_kReleaseMode) debugPrint('[Clash] $sanitized');
  }

  void setCorePath(String path) => _corePath = path;
  bool get coreExists => File(_corePath).existsSync();
  String get corePath => _corePath;
  String get configDir => _configDir;
}
