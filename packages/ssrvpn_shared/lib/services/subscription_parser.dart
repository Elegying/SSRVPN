import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../models/proxy_group.dart';
import '../models/proxy_node.dart';
import '../utils/proxy_node_usage_policy.dart';

part 'subscription_parser_base64_part.dart';
part 'subscription_parser_naming_part.dart';
part 'subscription_parser_ssr_part.dart';
part 'subscription_parser_uri_part.dart';
part 'subscription_parser_yaml_part.dart';

/// 订阅解析服务 - 跨平台共享的核心逻辑
///
/// 统一处理所有订阅格式，保证三端解析结果一致：
/// - Clash YAML 格式
/// - Base64 编码的订阅内容
/// - URI 列表（ssr://, ss://, vmess://, vless://, trojan://, anytls://,
///   hysteria://, hysteria2://, tuic://, snell://, socks5://, http://）
class SubscriptionParser {
  static const proxySourceKey = 'ssrvpn-subscription';
  static const standaloneGroupName = '单独节点';

  /// 统一订阅解析入口：自动检测格式，返回 YAML 格式的 proxies 段
  ///
  /// 返回值为 Clash YAML 字符串（包含 `proxies:` 段），可直接合并到配置中。
  /// 返回 null 表示内容无法解析为任何已知格式。
  static String? parseSubscriptionContent(String content) {
    if (content.trim().isEmpty) return null;

    final decoded = tryDecodeBase64(content);
    final body = decoded != content ? decoded : content;

    if (_looksLikeYaml(body)) {
      final section = extractSection(body, 'proxies');
      if (section.trim().isNotEmpty) return body;
    }

    final uriYaml = uriListToYaml(body);
    if (uriYaml != null) return uriYaml;

    final singleProxy = proxyFromUri(body.trim());
    if (singleProxy != null) {
      return 'proxies:\n  - ${_jsonEncode(singleProxy)}\n';
    }

    return null;
  }

  /// 从 URI 列表文本生成 Clash YAML
  static String? uriListToYaml(String content) {
    return _SubscriptionUriParser.uriListToYaml(content);
  }

  /// 解析单个代理 URI 为 Clash 代理配置 Map
  static Map<String, dynamic>? proxyFromUri(String line) {
    return _SubscriptionUriParser.proxyFromUri(line);
  }

  /// 判断是否为SSR链接
  static bool isSsrLink(String input) =>
      _SsrSubscriptionParser.isSsrLink(input);

  /// 导入SSR链接，返回生成的YAML配置片段
  static String? importSsrLink(String ssrLink) {
    return _SsrSubscriptionParser.importSsrLink(ssrLink);
  }

  /// 解析 YAML 配置，提取代理节点和代理组
  static ParsedSubscription parseYaml(String rawYaml) {
    return _SubscriptionYamlParser.parseYaml(rawYaml);
  }

  /// 从 YAML 文本中提取指定段落
  static String extractSection(String rawYaml, String sectionName) {
    return _SubscriptionYamlParser.extractSection(rawYaml, sectionName);
  }

  /// 生成唯一节点名，遇到重名自动加后缀
  static String uniqueProxyName(String baseName, Set<String> usedNames) {
    return _SubscriptionNaming.uniqueProxyName(baseName, usedNames);
  }

  /// 对节点列表去重（同名+同服务器+同端口视为重复）
  static List<Map<String, dynamic>> deduplicateProxies(
    List<Map<String, dynamic>> proxies,
  ) {
    return _SubscriptionNaming.deduplicateProxies(proxies);
  }

  /// 判断是否为Base64编码
  static bool isLikelyBase64(String str) {
    return _SubscriptionBase64.isLikelyBase64(str);
  }

  /// 尝试解码可能为Base64的内容
  static String tryDecodeBase64(String body) {
    return _SubscriptionBase64.tryDecodeBase64(body);
  }
}

String _jsonEncode(Object? value) => jsonEncode(value);

bool _looksLikeYaml(String text) {
  try {
    final document = loadYaml(text);
    return document is Map && document['proxies'] is List;
  } catch (_) {
    return false;
  }
}

class _SsCredentials {
  const _SsCredentials({required this.cipher, required this.password});

  final String cipher;
  final String password;
}

/// 解析后的订阅数据
class ParsedSubscription {
  final List<ProxyNode> nodes;
  final List<ProxyGroup> groups;

  ParsedSubscription({required this.nodes, required this.groups});

  factory ParsedSubscription.empty() {
    return ParsedSubscription(nodes: [], groups: []);
  }

  bool get isEmpty => nodes.isEmpty;
  bool get isNotEmpty => nodes.isNotEmpty;
}
