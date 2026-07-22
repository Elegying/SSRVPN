import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../models/app_settings.dart';
import '../constants/app_constants.dart';
import '../utils/bounded_yaml.dart';
import '../utils/proxy_node_usage_policy.dart';
import '../utils/runtime_config_name_policy.dart';

/// Clash 配置生成器 - 跨平台共享的核心逻辑
///
/// 生成通用的 Clash 配置，平台特定的配置可以通过继承或组合方式扩展
class ClashConfigGenerator {
  static const int isolateThreshold = 256 * 1024;
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
  /// [latencyTestUrl] 自动选择/故障转移组使用的探测 URL
  /// [includeFallbackGroup] 是否额外写入故障转移组
  /// [extraSelectGroupNames] 额外的 select 代理组名称
  /// [extraRulesBeforeDirect] 插入在内置直连规则前的平台规则
  /// [includeGeoIpRules] 平台已确认 GEOIP 数据可用时写入 GEOIP 规则
  static String generateConfig(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
    String? platformHeader,
    String? tunConfig,
    String? dnsConfig,
    String? dnsListen,
    String? latencyTestUrl,
    bool includeFallbackGroup = false,
    Iterable<String> extraSelectGroupNames = const [],
    Iterable<String> extraRulesBeforeDirect = const [],
    bool includeGeoIpRules = false,
  }) {
    final proxyNames = extractProxyNames(rawYaml);
    final proxiesText = buildProxiesText(rawYaml);
    if (proxyNames.isEmpty || proxiesText.isEmpty) {
      throw Exception('订阅中没有可用节点，请先刷新订阅');
    }
    final seenProxyNames = <String>{};
    for (final proxyName in proxyNames) {
      if (!seenProxyNames.add(proxyName)) {
        throw FormatException(
          '订阅中的节点名称重复：“$proxyName”，请刷新订阅或修改节点名称后重试',
        );
      }
    }
    final normalizedExtraGroupNames =
        RuntimeConfigNamePolicy.normalizeExtraGroupNames(
      extraSelectGroupNames,
    );
    final reservedRuntimeNames = <String>{
      ...RuntimeConfigNamePolicy.reservedProxyNames,
      ...normalizedExtraGroupNames,
    };
    String? conflictingProxyName;
    for (final proxyName in proxyNames) {
      if (reservedRuntimeNames.contains(proxyName)) {
        conflictingProxyName = proxyName;
        break;
      }
    }
    if (conflictingProxyName != null) {
      throw FormatException(
        '节点名称“$conflictingProxyName”属于 Mihomo/SSRVPN 运行时保留名称，'
        '请刷新订阅或修改节点名称后重试',
      );
    }

    final selectedProxyNames = List<String>.from(proxyNames);
    final canonicalPreferredNodeName = preferredNodeName == null
        ? null
        : _canonicalProxyName(preferredNodeName);
    if (canonicalPreferredNodeName != null &&
        canonicalPreferredNodeName.isNotEmpty &&
        selectedProxyNames.remove(canonicalPreferredNodeName)) {
      selectedProxyNames.insert(0, canonicalPreferredNodeName);
    }
    final healthCheckUrl = latencyTestUrl ?? settings.latencyTestUrl;

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
    result.writeln('# SSRVPN IPv4 / IPv6 双栈配置');
    result.writeln('ipv6: true');
    result.writeln('etag-support: true');
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
      result.writeln('  inet6-address:');
      result.writeln('    - ${AppConstants.tunInet6Address}');
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
      if (dnsListen != null && dnsListen.isNotEmpty) {
        result.writeln('  listen: $dnsListen');
      }
      result.writeln('  ipv6: true');
      result.writeln('  enhanced-mode: fake-ip');
      result.writeln('  respect-rules: true');
      result.writeln('  fake-ip-range: ${AppConstants.fakeIpRange}');
      result.writeln('  fake-ip-range6: ${AppConstants.fakeIpRange6}');
      result.writeln('  default-nameserver:');
      for (final ns in AppConstants.defaultNameservers) {
        result.writeln('    - $ns');
      }
      result.writeln('  nameserver:');
      for (final ns in AppConstants.trustedProxyNameservers) {
        result.writeln('    - ${_quote(ns)}');
      }
      result.writeln('  proxy-server-nameserver:');
      for (final ns in AppConstants.domesticDohNameservers) {
        result.writeln('    - ${_quote(ns)}');
      }
      for (final ns in AppConstants.defaultNameservers) {
        result.writeln('    - $ns');
      }
      result.writeln('  direct-nameserver:');
      for (final ns in AppConstants.domesticDohNameservers) {
        result.writeln('    - ${_quote(ns)}');
      }
      result.writeln('  direct-nameserver-follow-policy: true');
      result.writeln('  nameserver-policy:');
      result.writeln("    '+.cn':");
      for (final ns in AppConstants.domesticDohNameservers) {
        result.writeln('      - ${_quote(ns)}');
      }
      for (final domain in AppConstants.openAiDomainSuffixes) {
        result.writeln("    '+.$domain':");
        for (final ns in AppConstants.trustedProxyNameservers) {
          result.writeln('      - ${_quote(ns)}');
        }
      }
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
    result.writeln("    url: ${_quote(healthCheckUrl)}");
    result.writeln('    interval: ${AppConstants.latencyTestInterval}');
    if (includeFallbackGroup) {
      result.writeln('  - name: 故障转移');
      result.writeln('    type: fallback');
      result.writeln('    proxies:');
      for (final name in proxyNames) {
        result.writeln("      - ${_quote(name)}");
      }
      result.writeln("    url: ${_quote(healthCheckUrl)}");
      result.writeln('    interval: ${AppConstants.latencyTestInterval}');
    }
    for (final groupName in normalizedExtraGroupNames) {
      result.writeln('  - name: ${_quote(groupName)}');
      result.writeln('    type: select');
      result.writeln('    proxies:');
      for (final name in selectedProxyNames) {
        result.writeln("      - ${_quote(name)}");
      }
    }

    // 规则 Provider。下载路径为相对路径，确保 Mihomo 将缓存写在 HomeDir 内。
    // Mihomo 核心启动后会通过 API 触发一次更新；这里不写 interval，避免周期刷新。
    result.writeln();
    result.writeln('rule-providers:');
    _writeRuleProvider(
      result,
      name: AppConstants.geositeCnRuleProviderName,
      behavior: 'domain',
      path: AppConstants.geositeCnRuleProviderPath,
      url: AppConstants.geositeCnRuleProviderUrl,
    );
    _writeRuleProvider(
      result,
      name: AppConstants.geoipCnRuleProviderName,
      behavior: 'ipcidr',
      path: AppConstants.geoipCnRuleProviderPath,
      url: AppConstants.geoipCnRuleProviderUrl,
    );

    // 规则。按首次出现顺序去重，确保用户强制代理优先于内置直连，
    // 同时避免重复 matcher 让运行配置含义变得含混。
    final orderedRules = <String>{};
    orderedRules.addAll(buildForceProxyRules(settings));
    orderedRules.addAll(
      extraRulesBeforeDirect.map((rule) => rule.trim()).where(
            (rule) => rule.isNotEmpty,
          ),
    );
    orderedRules.addAll(AppConstants.openAiProxyRules);
    orderedRules.addAll(AppConstants.defaultRuleProviderDirectRules);
    orderedRules.addAll(AppConstants.defaultDirectRules);
    if (includeGeoIpRules) {
      orderedRules.addAll(AppConstants.defaultGeoipRules);
    }
    orderedRules.add(AppConstants.defaultMatchRule);

    result.writeln();
    result.writeln('rules:');
    for (final rule in orderedRules) {
      result.writeln('  - ${_quote(rule)}');
    }

    return result.toString();
  }

  /// Generates large runtime configurations away from the UI isolate.
  ///
  /// Small subscriptions stay synchronous to avoid isolate startup overhead;
  /// large subscriptions are copied into a short-lived isolate so parsing and
  /// serialization cannot freeze connection controls or animations.
  static Future<String> generateConfigAsync(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
    String? platformHeader,
    String? tunConfig,
    String? dnsConfig,
    String? dnsListen,
    String? latencyTestUrl,
    bool includeFallbackGroup = false,
    Iterable<String> extraSelectGroupNames = const [],
    Iterable<String> extraRulesBeforeDirect = const [],
    bool includeGeoIpRules = false,
  }) {
    final extraGroups = List<String>.of(extraSelectGroupNames);
    final extraRules = List<String>.of(extraRulesBeforeDirect);

    String generate() => generateConfig(
          rawYaml,
          settings,
          preferredNodeName: preferredNodeName,
          platformHeader: platformHeader,
          tunConfig: tunConfig,
          dnsConfig: dnsConfig,
          dnsListen: dnsListen,
          latencyTestUrl: latencyTestUrl,
          includeFallbackGroup: includeFallbackGroup,
          extraSelectGroupNames: extraGroups,
          extraRulesBeforeDirect: extraRules,
          includeGeoIpRules: includeGeoIpRules,
        );

    if (rawYaml.length < isolateThreshold) {
      return Future<String>.value(generate());
    }
    return Isolate.run(generate);
  }

  /// 从 YAML 中提取代理节点名称
  static List<String> extractProxyNames(String rawYaml) {
    try {
      final proxies = _parseProxyList(rawYaml);
      if (proxies != null) {
        return proxies
            .whereType<Map>()
            .where(ProxyNodeUsagePolicy.isRunnableProxyMap)
            .map((proxy) => _canonicalProxyName(proxy['name']))
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
          if (!ProxyNodeUsagePolicy.isRunnableProxyMap(proxy)) continue;
          final name = _canonicalProxyName(proxy['name']);
          if (name.isEmpty) continue;
          final normalizedProxy = Map<Object?, Object?>.from(proxy)
            ..['name'] = name;
          buffer.writeln(
            '  - ${jsonEncode(_plainYamlValue(normalizedProxy))}',
          );
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
    final yaml = BoundedYaml.load(rawYaml);
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
          final unquotedName = _unquoteName(name);
          if (ProxyNodeUsagePolicy.isSubscriptionInfoName(unquotedName)) {
            continue;
          }
          final canonicalName = _canonicalProxyName(unquotedName);
          if (canonicalName.isNotEmpty) names.add(canonicalName);
        }
      }

      return names;
    } catch (_) {
      return [];
    }
  }

  static String _unquoteName(String name) {
    if (name.startsWith('"') && name.endsWith('"')) {
      return name.substring(1, name.length - 1);
    }
    if (name.startsWith("'") && name.endsWith("'")) {
      return name.substring(1, name.length - 1);
    }
    return name;
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

  static String _canonicalProxyName(Object? value) =>
      _sanitizeScalar(value?.toString() ?? '').trim();

  /// 构建强制代理规则
  static List<String> buildForceProxyRules(AppSettings settings) {
    return buildForceProxyRulesFromSites(settings.forceProxySites);
  }

  /// 从用户输入的站点列表构建强制代理规则。
  ///
  /// 该入口不依赖平台 AppSettings 类型，三端可直接复用同一套
  /// IPv4/IPv6 主机规范化、去重和 Clash rule 生成逻辑。
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
        rules.add('IP-CIDR6,$host/128,PROXY,no-resolve');
      }
    }

    return rules;
  }

  static void _writeRuleProvider(
    StringBuffer result, {
    required String name,
    required String behavior,
    required String path,
    required String url,
  }) {
    result.writeln('  $name:');
    result.writeln('    type: http');
    result.writeln('    behavior: $behavior');
    result.writeln('    format: mrs');
    result.writeln('    path: ${_quote(path)}');
    result.writeln('    url: ${_quote(url)}');
    result.writeln('    proxy: ${AppConstants.ruleProviderDownloadProxy}');
  }

  /// 为 YAML 字符串添加引号（如果需要）
  static String _quote(String value) {
    final sanitized = value
        .replaceAll('\\', '\\\\')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    return "'${sanitized.replaceAll("'", "''")}'";
  }
}
