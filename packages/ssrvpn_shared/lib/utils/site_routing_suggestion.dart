import '../models/app_settings.dart';
import 'force_proxy_site_policy.dart';

/// Add without truncating an existing rule or silently overriding its opposite.
List<String> addDiagnosticRoutingSite(AppSettings settings, String host,
    {required bool direct}) {
  if (settings.proxyMode != ProxyMode.rule) {
    throw const FormatException('请先在节点页切换到规则模式，再添加网站规则');
  }
  if (!ForceProxySitePolicy.isValidHost(host)) {
    throw const FormatException('网站域名无效');
  }
  bool matches(String site) {
    final saved = ForceProxySitePolicy.extractHost(site);
    return saved != null && (host == saved || host.endsWith('.$saved'));
  }

  final opposite =
      direct ? settings.forceProxySites : settings.forceDirectSites;
  if (opposite.any((site) {
    final saved = ForceProxySitePolicy.extractHost(site);
    return saved != null && (matches(site) || saved.endsWith('.$host'));
  })) {
    throw const FormatException('此网站已被相反规则覆盖，请先到节点页的强制代理/直连列表中调整原规则');
  }
  final current = List<String>.of(
      direct ? settings.forceDirectSites : settings.forceProxySites);
  if (current.any(matches)) throw const FormatException('此网站已有同类规则，请重新连接后复测');
  final empty = current.indexWhere((entry) => entry.trim().isEmpty);
  if (empty < 0) throw const FormatException('规则列表已满，请先到节点页删除不需要的规则');
  current[empty] = host;
  return current;
}
