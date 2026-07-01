import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';
import '../models/app_settings.dart';

/// Clash Meta 核心管理服务 (Android 版)
///
/// 继承 [ClashServiceBase] 共享 API/延迟/健康检查/状态/端口，
/// 仅实现 Android 特有：MethodChannel 桥接、gomobile VPN 启停、
/// MMDB 解压、TUN 配置、磁贴/通知集成。
class ClashService extends ClashServiceBase {
  static const _channel = MethodChannel('com.ssrvpn/native');

  String _corePath = '';
  String _nativeLibDir = '';

  /// 磁贴/通知触发的自动连接回调
  VoidCallback? onAutoConnect;

  String get corePath => _corePath;
  bool get coreExists => File(_corePath).existsSync();
  void setCorePath(String path) => _corePath = path;

  // ── onStopRequired ──

  @override
  Future<void> onStopRequired() => stop();

  // ── 平台调试日志 ──

  @override
  void debugLog(String message) => debugPrint('[Clash] $message');

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

    _nativeLibDir = await _getNativeLibraryDir();
    _corePath = '$_nativeLibDir/libgojni.so';

    setPaths(configDir: configDir, configPath: configPath);
    initHttpClient();

    log('nativeLibDir: $_nativeLibDir');
    log('核心路径: $_corePath');
    log('配置目录: $configDir');

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'autoConnect') {
        log('收到原生自动连接请求');
        onAutoConnect?.call();
      } else if (call.method == 'vpnStateChanged') {
        final connected = call.arguments == true;
        if (isRunning != connected) {
          setRunning(connected);
          log(connected ? '原生通知: VPN 已连接' : '原生通知: VPN 已断开');
          if (connected) {
            startStatusMonitor();
          } else {
            stopStatusMonitor();
          }
          notifyStatusChanged();
        }
      }
    });

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
  }

  Future<void> _syncNativeState() async {
    try {
      final running = await _channel.invokeMethod<bool>('isCoreRunning');
      if (running == true && !isRunning) {
        setRunning(true);
        log('检测到 VPN 已在运行（磁贴启动），同步状态');
        startStatusMonitor();
      }
    } catch (e) {
      log('查询原生 VPN 状态失败: $e');
    }
  }

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

  // ── 原生路径 ──

  Future<String> _getNativeLibraryDir() async {
    try {
      final result = await _channel.invokeMethod<String>('getNativeLibraryDir');
      if (result != null && result.isNotEmpty) return result;
    } catch (e) {
      log('MethodChannel getNativeLibraryDir 失败: $e');
    }
    for (final dir in ['/data/app/~~/lib/arm64', '/data/app/lib/arm64']) {
      if (Directory(dir).existsSync()) {
        for (final e in Directory(dir).listSync()) {
          if (e.path.contains('libgojni')) return dir;
        }
      }
    }
    return '/data/app/lib/arm64';
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
    final mmdbPath = '$configDir/country.mmdb';
    try {
      if ((await File(mmdbPath).exists() &&
              await File(mmdbPath).length() > 1024 * 1024) ||
          (await File(metadbPath).exists() &&
              await File(metadbPath).length() > 1024 * 1024)) {
        log('✅ MMDB 已存在');
        return;
      }
    } catch (_) {}

    try {
      await Directory(configDir).create(recursive: true);
      final data = await rootBundle.load('assets/geoip.metadb.gz');
      final compressed = data.buffer.asUint8List();
      final bytes = await Isolate.run(() => gzip.decode(compressed));
      final f = File(metadbPath);
      final temp = File('$metadbPath.tmp');
      await temp.writeAsBytes(bytes);
      await temp.rename(f.path);
      log('✅ MMDB 已从内置资源解压 (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)');
    } catch (e) {
      log('⚠️ 内置资源复制失败: $e');
      log('❌ MMDB 不可用，GEOIP 规则将跳过');
    }
  }

  // ── 配置生成 ──

  List<String> _buildForceProxyRules(AppSettings settings) {
    return ClashConfigGenerator.buildForceProxyRulesFromSites(
      settings.forceProxySites,
    );
  }

  String generateClashConfig(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) {
    final proxyNames = extractProxyNames(rawYaml);
    final proxiesText = extractSection(rawYaml, 'proxies');
    if (proxyNames.isEmpty || proxiesText.isEmpty) {
      throw Exception('订阅中没有可用节点，请先刷新订阅');
    }

    final selectedProxyNames = List<String>.from(proxyNames);
    if (preferredNodeName != null &&
        selectedProxyNames.remove(preferredNodeName)) {
      selectedProxyNames.insert(0, preferredNodeName);
    }

    final mmdbExists = (() {
      try {
        final m = File('$configDir/country.mmdb');
        if (m.existsSync() && m.lengthSync() > 1024 * 1024) return true;
        final g = File('$configDir/geoip.metadb');
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
      result.writeln('secret: ${yamlQuote(settings.apiSecret)}');
    }

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

    result.writeln();
    result.writeln('proxies:');
    result.writeln(proxiesText);

    result.writeln();
    result.writeln('proxy-groups:');
    result.writeln('  - name: PROXY');
    result.writeln('    type: select');
    result.writeln('    proxies:');
    for (final name in selectedProxyNames) {
      result.writeln("      - ${yamlQuote(name)}");
    }
    result.writeln('  - name: GLOBAL');
    result.writeln('    type: select');
    result.writeln('    proxies:');
    result.writeln("      - 'PROXY'");
    for (final name in selectedProxyNames) {
      result.writeln("      - ${yamlQuote(name)}");
    }
    result.writeln('  - name: 自动选择');
    result.writeln('    type: url-test');
    result.writeln('    proxies:');
    for (final name in proxyNames) {
      result.writeln("      - ${yamlQuote(name)}");
    }
    result.writeln("    url: 'http://www.gstatic.com/generate_204'");
    result.writeln('    interval: 300');

    result.writeln();
    result.writeln('rules:');
    for (final rule in _buildForceProxyRules(settings)) {
      result.writeln('  - ${yamlQuote(rule)}');
    }
    result.writeln("  - 'DOMAIN-SUFFIX,cn,DIRECT'");
    if (mmdbExists) {
      result.writeln("  - 'GEOIP,CN,DIRECT'");
      result.writeln("  - 'GEOIP,LAN,DIRECT,no-resolve'");
    }
    result.writeln("  - 'MATCH,PROXY'");

    return result.toString();
  }

  Future<void> writeConfig(String configContent) async {
    await writeStringAtomically(File(configPath), configContent);
  }

  // ── 进程控制 ──

  Future<bool> start({String? nodeName}) async {
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
      log('配置: $configPath');

      if (!File(configPath).existsSync()) {
        log('❌ 配置文件不存在');
        setLastStartError('找不到生成的 VPN 配置文件');
        return false;
      }

      await Directory('$configDir/tmp').create(recursive: true);

      final result = await _channel.invokeMethod('startCoreWithVpn', {
        'configDir': configDir,
        'configPath': configPath,
        'apiPort': settings.apiPort,
        'apiSecret': settings.apiSecret,
        'nodeName': nodeName,
      }).timeout(
        const Duration(seconds: 55),
        onTimeout: () async {
          try {
            await _channel
                .invokeMethod('stopCore')
                .timeout(const Duration(seconds: 5), onTimeout: () => null);
          } catch (_) {}
          setRunning(false);
          _notifyNativeStateChange();
          throw TimeoutException('设备性能不足，请重新连接');
        },
      );

      if (result == true) {
        setRunning(true);
        log('✅ Mihomo 启动成功 (gomobile)');
        notifyStatusChanged();
        _notifyNativeStateChange();
        _saveConfigForTile(nodeName);
        startStatusMonitor();
        return true;
      } else {
        log('❌ 核心启动失败: $result');
        setLastStartError(result?.toString() ?? '无法启动VPN核心');
        return false;
      }
    } on PlatformException catch (e) {
      log('❌ 启动异常: ${e.message}');
      final msg = e.message ?? '无法启动VPN核心';
      if (e.code == 'PERMISSION_DENIED') {
        log('⚠️ 用户拒绝了 VPN 权限');
        setLastStartError('用户拒绝了 VPN 权限');
      } else if (msg == '设备性能不足，请重新连接') {
        setLastStartError(msg);
      } else {
        setLastStartError(msg);
      }
      return false;
    } on TimeoutException catch (e) {
      final msg = e.message ?? '设备性能不足，请重新连接';
      log('❌ $msg');
      setLastStartError(msg);
      return false;
    } catch (e, stack) {
      log('❌ 启动异常: $e');
      log('堆栈: $stack');
      setLastStartError('无法启动VPN核心: $e');
      return false;
    }
  }

  Future<void> stop() async {
    stopStatusMonitor();
    resetHealthCheckFailures();

    try {
      await _channel.invokeMethod('stopCore');
      log('核心已停止');
    } catch (e) {
      log('停止异常: $e');
    }

    setRunning(false);
    notifyStatusChanged();
    _notifyNativeStateChange();
  }

  void _notifyNativeStateChange() {
    try {
      _channel.invokeMethod('notifyVpnStateChanged');
    } catch (_) {}
  }

  Future<void> _saveConfigForTile(String? nodeName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('configDir', configDir);
      await prefs.setString('configPath', configPath);
      await prefs.setInt('apiPort', settings.apiPort);
      await prefs.remove('apiSecret');
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
      log('更新 VPN 通知失败: $e');
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
