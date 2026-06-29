import '../models/app_settings.dart';
import '../constants/app_constants.dart';

/// Clash 配置生成器 - 跨平台共享的核心逻辑
/// 
/// 生成通用的 Clash 配置，平台特定的配置可以通过继承或组合方式扩展
class ClashConfigGenerator {
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
    final proxiesText = extractSection(rawYaml, 'proxies');
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
      result.writeln('secret: "${settings.apiSecret}"');
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
      final lines = rawYaml.split('\n');
      final names = <String>[];
      bool inProxies = false;
      int proxiesIndent = 0;
      
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed == 'proxies:') {
          inProxies = true;
          proxiesIndent = line.indexOf('proxies:');
          continue;
        }
        
        if (inProxies) {
          if (trimmed.isEmpty) {
            continue;
          }
          
          final currentIndent = line.indexOf(trimmed);
          // 如果当前行的缩进小于等于 proxies 的缩进，说明遇到了新的顶级键
          if (currentIndent <= proxiesIndent && trimmed.isNotEmpty) {
            inProxies = false;
            continue;
          }
          
          if (trimmed.startsWith('- name:')) {
            final name = trimmed.substring(7).trim();
            // 移除引号
            if (name.startsWith('"') && name.endsWith('"')) {
              names.add(name.substring(1, name.length - 1));
            } else if (name.startsWith("'") && name.endsWith("'")) {
              names.add(name.substring(1, name.length - 1));
            } else {
              names.add(name);
            }
          }
        }
      }
      
      return names;
    } catch (e) {
      return [];
    }
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

  /// 构建强制代理规则
  static List<String> buildForceProxyRules(AppSettings settings) {
    final rules = <String>[];
    
    for (final site in settings.forceProxySites) {
      if (site.startsWith('DOMAIN-SUFFIX,')) {
        rules.add('$site,PROXY');
      } else if (site.startsWith('DOMAIN,')) {
        rules.add('$site,PROXY');
      } else if (site.startsWith('IP-CIDR,')) {
        rules.add('$site,PROXY,no-resolve');
      } else if (site.startsWith('IP-CIDR6,')) {
        rules.add('$site,PROXY,no-resolve');
      } else {
        // 默认作为域名处理
        rules.add('DOMAIN-SUFFIX,$site,PROXY');
      }
    }
    
    return rules;
  }

  /// 为 YAML 字符串添加引号（如果需要）
  static String _quote(String value) {
    // 如果包含特殊字符，添加引号
    if (value.contains(':') || 
        value.contains('#') || 
        value.contains('{') || 
        value.contains('}') || 
        value.contains('[') || 
        value.contains(']') || 
        value.contains(',') || 
        value.contains('&') || 
        value.contains('*') || 
        value.contains('?') || 
        value.contains('|') || 
        value.contains('-') || 
        value.contains('<') || 
        value.contains('>') || 
        value.contains('=') || 
        value.contains('!') || 
        value.contains('%') || 
        value.contains('@') || 
        value.contains('`') ||
        value.contains(' ') ||
        value.contains("'") ||
        value.contains('"')) {
      // 使用双引号，并转义内部的双引号
      return '"${value.replaceAll('"', '\\"')}"';
    }
    
    return value;
  }
}
