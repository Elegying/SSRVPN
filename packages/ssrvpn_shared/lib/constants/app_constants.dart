/// SSRVPN 应用常量
///
/// 包含所有平台共享的常量定义
class AppConstants {
  // ── 端口 ──
  static const int defaultProxyPort = 7890;
  static const int defaultSocksPort = 7891;
  static const int defaultApiPort = 9090;

  // ── 超时时间 ──
  static const Duration healthCheckTimeout = Duration(seconds: 2);
  static const Duration startupTimeout = Duration(seconds: 15);
  static const Duration connectionTimeout = Duration(seconds: 30);
  static const Duration apiTimeout = Duration(seconds: 5);
  static const Duration dnsTimeout = Duration(seconds: 5);

  // ── 缓冲区大小 ──
  static const int maxLogBufferSize = 10000;
  static const int maxSubscriptionBytes = 20 * 1024 * 1024; // 20MB
  static const int maxYamlBytes = 2 * 1024 * 1024; // 2MB

  // ── 延迟测试 ──
  static const int defaultLatencyTestTimeout = 5000; // 毫秒
  static const String defaultLatencyTestUrl =
      'https://www.gstatic.com/generate_204';
  static const int latencyTestInterval = 300; // 秒

  // ── 重试机制 ──
  static const int maxRetries = 3;
  static const int retryDelayBase = 2; // 秒

  // ── 代理模式 ──
  static const String defaultProxyMode = 'rule';
  static const String defaultTunStack = 'gvisor';

  // ── DNS 配置 ──
  static const List<String> defaultNameservers = ['223.5.5.5', '119.29.29.29'];

  static const List<String> fallbackNameservers = [
    'https://dns.google/dns-query',
    'https://cloudflare-dns.com/dns-query',
    '8.8.8.8',
    '1.1.1.1',
  ];

  static const List<String> dohNameservers = [
    'https://dns.alidns.com/dns-query',
    'https://doh.pub/dns-query',
  ];

  // ── 文件路径 ──
  static const String configFileName = 'config.yaml';
  static const String subscriptionCacheFileName = 'subscription_cache.yaml';
  static const String settingsFileName = 'settings.json';
  static const String logFileName = 'ssrvpn.log';

  // ── 版本信息 ──
  static const String appName = 'SSRVPN';
  static const String appVersion = '3.4.4';
  static const String appUserAgent = '$appName/$appVersion';
  static const String appDescription = 'Cross-platform VPN client';

  // ── 网络配置 ──
  static const List<String> routeExcludeAddresses = [
    '192.168.0.0/16',
    '10.0.0.0/8',
    '172.16.0.0/12',
    '100.64.0.0/10',
    'fc00::/7',
    'fe80::/10',
  ];

  // ── Fake IP 配置 ──
  static const String fakeIpRange = '198.18.0.1/16';
  // Keep fake IPv6 answers outside fc00::/7. Desktop TUN configs deliberately
  // exclude ULA LAN traffic, so a ULA fake range would bypass the tunnel.
  static const String fakeIpRange6 = '2001:db8::1/64';
  static const String tunInet6Address = 'fdfe:dcba:9876::1/126';
  static const List<String> fakeIpFilter = [
    '*.lan',
    '*.local',
    '*.localhost',
    '*.googlevideo.com',
    '*.youtube.com',
    '*.ytimg.com',
    '*.ggpht.com',
    '*.googleapis.com',
    'dns.google',
    'www.google.com',
  ];

  // ── 代理规则 ──
  static const Duration ruleProviderStartupRefreshDelay = Duration(minutes: 10);
  static const String ruleProviderDownloadProxy = 'PROXY';
  static const String geositeCnRuleProviderName = 'ssrvpn-geosite-cn';
  static const String geoipCnRuleProviderName = 'ssrvpn-geoip-cn';
  static const List<String> ruleProviderNames = [
    geositeCnRuleProviderName,
    geoipCnRuleProviderName,
  ];
  static const String geositeCnRuleProviderPath =
      './providers/ssrvpn-geosite-cn.mrs';
  static const String geoipCnRuleProviderPath =
      './providers/ssrvpn-geoip-cn.mrs';
  // Pin the upstream commit so a mutable branch cannot silently change routing.
  // The built-in DOMAIN-SUFFIX/CN GeoIP rules below remain the offline fallback.
  static const String metaRulesCommit =
      '200e6a86736cfab29aae7b07dc266e59f13bc13d';
  static const String geositeCnRuleProviderUrl =
      'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/'
      '$metaRulesCommit/geo/geosite/cn.mrs';
  static const String geoipCnRuleProviderUrl =
      'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/'
      '$metaRulesCommit/geo/geoip/cn.mrs';

  static const List<String> defaultDirectRules = ['DOMAIN-SUFFIX,cn,DIRECT'];

  static const List<String> defaultRuleProviderDirectRules = [
    'RULE-SET,$geositeCnRuleProviderName,DIRECT',
    'RULE-SET,$geoipCnRuleProviderName,DIRECT,no-resolve',
  ];

  static const List<String> defaultGeoipRules = [
    'GEOIP,CN,DIRECT',
    'GEOIP,LAN,DIRECT,no-resolve',
  ];

  static const String defaultMatchRule = 'MATCH,PROXY';
}
