import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../models/app_settings.dart';
import '../constants/app_constants.dart';

/// Clash 配置生成器 - 跨平台共享的核心逻辑
///
/// 生成通用的 Clash 配置，平台特定的配置可以通过继承或组合方式扩展
class ClashConfigGenerator {
  static const _internalProxyKeys = {
    'ssrvpn-subscription',
    'group',
    'latency',
    'isOnline',
    'lastLatencyTest',
    'extra',
  };

  /// 生成基础 Clash 配置
  ///
  /// [rawYaml] 原始 YAML 配置（包含代理节点）
  /// [settings] 应用设置
  /// [preferredNodeName] 首选节点名称（可选）
  /// [platformHeader] 平台特定的配置头（可选）
  /// [tunConfig] 平台特定的 TUN 配置（可选）
  /// [dnsConfig] 平台特定的 DNS 配置（可选）
  static String generateConfig(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
    String? platformHeader,
    String? tunConfig,
    String? dnsConfig,
  }) {
    final proxyNames = extractProxyNames(rawYaml);
    final proxiesText = buildProxiesText(rawYaml);
    if (proxyNames.isEmpty || proxiesText.isEmpty) {
      throw Exception('订阅中没有可用节点，请先刷新订阅');
    }

    // 检查 MMDB 是否存在且有效（>1MB）
    final selectedProxyNames = List<String>.from(proxyNames);
    if (preferredNodeName != null &&
        selectedProxyNames.remove(preferredNodeName)) {
      selectedProxyNames.insert(0, preferredNodeName);
    }

    final result = StringBuffer();

    // 平台头
    result.writeln(platformHeader ?? '# ===== SSRVPN 配置 =====');

    // 基础配置
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

    // TUN 配置
    if (tunConfig != null) {
      result.writeln();
      result.writeln(tunConfig);
    } else if (settings.enableTun) {
      result.writeln();
      result.writeln('tun:');
      result.writeln('  enable: true');
      result.writeln('  stack: ${settings.tunStack}');
      result.writeln('  auto-route: true');
      result.writeln('  auto-detect-interface: true');
      result.writeln('  route-exclude-address:');
      for (final addr in AppConstants.routeExcludeAddresses) {
        result.writeln('    - $addr');
      }
      result.writeln('  dns-hijack:');
      result.writeln('    - any:53');
    }

    // DNS 配置
    if (dnsConfig != null) {
      result.writeln();
      result.writeln(dnsConfig);
    } else {
      result.writeln();
      result.writeln('dns:');
      result.writeln('  enable: true');
      result.writeln('  ipv6: false');
      result.writeln('  enhanced-mode: fake-ip');
      result.writeln('  fake-ip-range: ${AppConstants.fakeIpRange}');
      result.writeln('  default-nameserver:');
      for (final ns in AppConstants.defaultNameservers) {
        result.writeln('    - $ns');
      }
      result.writeln('  nameserver:');
      for (final ns in AppConstants.dohNameservers) {
        result.writeln('    - $ns');
      }
      for (final ns in AppConstants.defaultNameservers) {
        result.writeln('    - $ns');
      }
      result.writeln('  fallback:');
      for (final ns in AppConstants.fallbackNameservers) {
        result.writeln('    - $ns');
      }
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
      for (final filter in AppConstants.fakeIpFilter) {
        result.writeln("    - '$filter'");
      }
    }

    // 代理节点
    result.writeln();
    result.writeln('proxies:');
    result.writeln(proxiesText);

    // 代理组
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
    result.writeln("    url: '${AppConstants.defaultLatencyTestUrl}'");
    result.writeln('    interval: ${AppConstants.latencyTestInterval}');

    // 规则
    result.writeln();
    result.writeln('rules:');
    for (final rule in buildForceProxyRules(settings)) {
      result.writeln('  - ${_quote(rule)}');
    }
    for (final rule in AppConstants.defaultDirectRules) {
      result.writeln("  - '$rule'");
    }
    // 注意：GEOIP 规则需要平台特定的 MMDB 文件检查
    // 这里只添加基本规则，平台特定的规则由各平台添加
    result.writeln("  - '${AppConstants.defaultMatchRule}'");

    return result.toString();
  }

  /// 从 YAML 中提取代理节点名称
  static List<String> extractProxyNames(String rawYaml) {
    try {
      final proxies = _parseProxyList(rawYaml);
      if (proxies != null) {
        return proxies
            .whereType<Map>()
            .map((proxy) => proxy['name']?.toString().trim() ?? '')
            .where((name) => name.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return _extractProxyNamesFromText(rawYaml);
  }

  /// 安全重建 `proxies` 段内容。
  ///
  /// 订阅里的节点字段先由 YAML parser 解析，再以 JSON flow map 写回；
  /// JSON 是合法 YAML 子集，可避免节点名、密码等用户输入逃逸 YAML 结构。
  static String buildProxiesText(String rawYaml) {
    try {
      final proxies = _parseProxyList(rawYaml);
      if (proxies != null) {
        final buffer = StringBuffer();
        for (final proxy in proxies.whereType<Map>()) {
          final name = proxy['name']?.toString().trim();
          if (name == null || name.isEmpty) continue;
          buffer.writeln('  - ${jsonEncode(_plainYamlValue(proxy))}');
        }
        final text = buffer.toString().trimRight();
        if (text.isNotEmpty) return text;
      }
    } catch (_) {}
    return extractSection(rawYaml, 'proxies').trimRight();
  }

  /// 从 YAML 中提取指定部分
  static String extractSection(String rawYaml, String sectionName) {
    try {
      final lines = rawYaml.split('\n');
      final buffer = StringBuffer();
      bool inSection = false;
      int indentLevel = 0;

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed == '$sectionName:') {
          inSection = true;
          indentLevel = line.indexOf(sectionName);
          continue;
        }

        if (inSection) {
          if (trimmed.isEmpty) {
            continue;
          }

          final currentIndent = line.indexOf(trimmed);
          if (currentIndent <= indentLevel && trimmed.isNotEmpty) {
            // 遇到同级或更高级的键，退出当前部分
            break;
          }

          buffer.writeln(line);
        }
      }

      return buffer.toString();
    } catch (e) {
      return '';
    }
  }

  static List<dynamic>? _parseProxyList(String rawYaml) {
    final yaml = loadYaml(rawYaml);
    if (yaml is! Map) return null;
    final proxies = yaml['proxies'];
    return proxies is List ? proxies : null;
  }

  static List<String> _extractProxyNamesFromText(String rawYaml) {
    try {
      final lines = rawYaml.split('\n');
      final names = <String>[];
      var inProxies = false;
      var proxiesIndent = 0;

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed == 'proxies:') {
          inProxies = true;
          proxiesIndent = line.indexOf('proxies:');
          continue;
        }

        if (!inProxies || trimmed.isEmpty || trimmed.startsWith('#')) {
          continue;
        }

        final currentIndent = line.indexOf(trimmed);
        if (currentIndent <= proxiesIndent && trimmed.isNotEmpty) {
          inProxies = false;
          continue;
        }

        if (trimmed.startsWith('- name:')) {
          final name = trimmed.substring(7).trim();
          if (name.startsWith('"') && name.endsWith('"')) {
            names.add(name.substring(1, name.length - 1));
          } else if (name.startsWith("'") && name.endsWith("'")) {
            names.add(name.substring(1, name.length - 1));
          } else {
            names.add(name);
          }
        }
      }

      return names;
    } catch (_) {
      return [];
    }
  }

  static Object? _plainYamlValue(Object? value) {
    if (value == null || value is num || value is bool) return value;
    if (value is String) return _sanitizeScalar(value);
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (!_internalProxyKeys.contains(entry.key.toString()))
            entry.key.toString(): _plainYamlValue(entry.value),
      };
    }
    if (value is Iterable) {
      return value.map(_plainYamlValue).toList();
    }
    return _sanitizeScalar(value.toString());
  }

  static String _sanitizeScalar(String value) =>
      value.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '');

  /// 构建强制代理规则
  static List<String> buildForceProxyRules(AppSettings settings) {
    return buildForceProxyRulesFromSites(settings.forceProxySites);
  }

  /// 从用户输入的站点列表构建强制代理规则。
  ///
  /// 该入口不依赖平台 AppSettings 类型，三端可直接复用同一套
  /// IPv4-only 主机规范化、去重和 Clash rule 生成逻辑。
  static List<String> buildForceProxyRulesFromSites(
    Iterable<Object?>? forceProxySites,
  ) {
    final hosts = <String>{};
    final rules = <String>[];

    for (final site in forceProxySites ?? const <Object?>[]) {
      final host = AppSettings.extractForceProxyHost(site?.toString() ?? '');
      if (host == null || !hosts.add(host)) continue;

      final address = InternetAddress.tryParse(host);
      if (address == null) {
        rules.add('DOMAIN-SUFFIX,$host,PROXY');
      } else if (address.type == InternetAddressType.IPv4) {
        rules.add('IP-CIDR,$host/32,PROXY,no-resolve');
      } else {
        continue;
      }
    }

    return rules;
  }

  /// 为 YAML 字符串添加引号（如果需要）
  static String _quote(String value) {
    final sanitized = value
        .replaceAll('\\', '\\\\')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    return "'${sanitized.replaceAll("'", "''")}'";
  }
}
