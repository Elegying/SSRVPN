import '../utils/force_proxy_site_policy.dart';
import '../constants/app_constants.dart';

/// 应用设置数据模型 — 跨平台共享
///
/// 所有平台共用此类。通过 re-export 暴露给各平台子项目。
/// 这里只保留连接和运行时状态；用户可配置的软件设置不再持久化。
class AppSettings {
  static const int forceProxySiteLimit = ForceProxySitePolicy.defaultLimit;

  // ── 端口 ──
  int proxyPort; // mixed-port, 默认7890
  int socksPort; // 默认7891
  int apiPort; // Clash API端口, 默认9090
  String apiSecret; // API密钥

  // ── 代理模式 ──
  ProxyMode proxyMode;

  // ── TUN / VPN ──
  bool enableTun;
  String tunStack; // gvisor / system / mixed

  // ── 延迟测试 ──
  String latencyTestUrl;
  String? lastSelectedNodeName;
  int latencyTestTimeout; // 毫秒

  // ── 强制代理站点 ──
  List<String> forceProxySites;

  AppSettings({
    this.proxyPort = 7890,
    this.socksPort = 7891,
    this.apiPort = 9090,
    this.apiSecret = '',
    this.proxyMode = ProxyMode.rule,
    bool? enableTun,
    bool? tunMode,
    bool? enableSystemProxy,
    String tunStack = 'gvisor',
    this.latencyTestUrl = AppConstants.defaultLatencyTestUrl,
    String? lastSelectedNodeName,
    String? lastSelectedNode,
    this.latencyTestTimeout = 5000,
    Iterable<Object?>? forceProxySites,
  })  : enableTun = enableTun ??
            tunMode ??
            (enableSystemProxy == null ? false : !enableSystemProxy),
        tunStack = _parseTunStack(tunStack),
        lastSelectedNodeName = lastSelectedNodeName ?? lastSelectedNode,
        forceProxySites = normalizeForceProxySites(forceProxySites);

  // ── 便捷 getter/setter ──

  String? get lastSelectedNode => lastSelectedNodeName;
  set lastSelectedNode(String? value) => lastSelectedNodeName = value;

  bool get tunMode => enableTun;
  set tunMode(bool value) => enableTun = value;

  bool get enableSystemProxy => !enableTun;
  set enableSystemProxy(bool value) => enableTun = !value;

  // ── copyWith ──

  AppSettings copyWith({
    int? proxyPort,
    int? socksPort,
    int? apiPort,
    String? apiSecret,
    ProxyMode? proxyMode,
    bool? enableTun,
    bool? tunMode,
    bool? enableSystemProxy,
    String? tunStack,
    String? latencyTestUrl,
    String? lastSelectedNodeName,
    String? lastSelectedNode,
    int? latencyTestTimeout,
    Iterable<Object?>? forceProxySites,
  }) {
    return AppSettings(
      proxyPort: proxyPort ?? this.proxyPort,
      socksPort: socksPort ?? this.socksPort,
      apiPort: apiPort ?? this.apiPort,
      apiSecret: apiSecret ?? this.apiSecret,
      proxyMode: proxyMode ?? this.proxyMode,
      enableTun: enableTun ??
          tunMode ??
          (enableSystemProxy == null ? this.enableTun : !enableSystemProxy),
      tunStack: tunStack ?? this.tunStack,
      latencyTestUrl: latencyTestUrl ?? this.latencyTestUrl,
      lastSelectedNodeName:
          lastSelectedNodeName ?? lastSelectedNode ?? this.lastSelectedNodeName,
      latencyTestTimeout: latencyTestTimeout ?? this.latencyTestTimeout,
      forceProxySites: forceProxySites ?? this.forceProxySites,
    );
  }

  // ── JSON 序列化 ──

  Map<String, dynamic> toJson() {
    return {
      'proxyPort': proxyPort,
      'socksPort': socksPort,
      'apiPort': apiPort,
      'apiSecret': apiSecret,
      'proxyMode': proxyMode.name,
      'enableTun': enableTun,
      'tunStack': tunStack,
      'latencyTestUrl': latencyTestUrl,
      'lastSelectedNodeName': lastSelectedNodeName,
      'latencyTestTimeout': latencyTestTimeout,
      'forceProxySites': forceProxySites,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      proxyPort: _parsePort(json['proxyPort'], 7890),
      socksPort: _parsePort(json['socksPort'], 7891),
      apiPort: _parsePort(json['apiPort'], 9090),
      apiSecret: json['apiSecret']?.toString() ?? '',
      proxyMode: _parseProxyMode(json['proxyMode'] as String?),
      enableTun: _parseEnableTun(json),
      tunStack: json['tunStack']?.toString() ?? 'gvisor',
      latencyTestUrl: _parseLatencyTestUrl(json['latencyTestUrl']),
      lastSelectedNodeName:
          (json['lastSelectedNodeName'] ?? json['lastSelectedNode']) as String?,
      latencyTestTimeout: _parseTimeout(json['latencyTestTimeout'], 5000),
      forceProxySites: json['forceProxySites'] is Iterable
          ? (json['forceProxySites'] as Iterable)
              .map((e) => e?.toString() ?? '')
          : null,
    );
  }

  // ── 比较 ──

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppSettings &&
        other.proxyPort == proxyPort &&
        other.socksPort == socksPort &&
        other.apiPort == apiPort &&
        other.apiSecret == apiSecret &&
        other.proxyMode == proxyMode &&
        other.enableTun == enableTun &&
        other.tunStack == tunStack &&
        other.latencyTestUrl == latencyTestUrl &&
        other.lastSelectedNodeName == lastSelectedNodeName &&
        other.latencyTestTimeout == latencyTestTimeout &&
        _listEquals(other.forceProxySites, forceProxySites);
  }

  @override
  int get hashCode {
    return Object.hash(
      proxyPort,
      socksPort,
      apiPort,
      apiSecret,
      proxyMode,
      enableTun,
      tunStack,
      latencyTestUrl,
      lastSelectedNodeName,
      latencyTestTimeout,
      Object.hashAll(forceProxySites),
    );
  }

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ── 静态工具方法 ──

  static List<String> normalizeForceProxySites(Iterable<Object?>? sites) {
    return ForceProxySitePolicy.normalize(
      sites,
      limit: forceProxySiteLimit,
    );
  }

  static String? extractForceProxyHost(String site) {
    return ForceProxySitePolicy.extractHost(site);
  }

  static int _parsePort(Object? value, int fallback) {
    final port = int.tryParse(value?.toString() ?? '');
    return port != null && port >= 1 && port <= 65535 ? port : fallback;
  }

  static int _parseTimeout(Object? value, int fallback) {
    final timeout = int.tryParse(value?.toString() ?? '');
    return timeout != null && timeout >= 500 && timeout <= 60000
        ? timeout
        : fallback;
  }

  static String _parseTunStack(Object? value) {
    final stack = value?.toString().trim().toLowerCase();
    return switch (stack) {
      'system' || 'mixed' || 'gvisor' => stack!,
      _ => 'gvisor',
    };
  }

  static bool _parseBool(Object? value, bool fallback) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is String) return value == 'true';
    if (value is int) return value != 0;
    return fallback;
  }

  static bool _parseEnableTun(Map<String, dynamic> json) {
    if (json.containsKey('enableTun')) {
      return _parseBool(json['enableTun'], false);
    }
    if (json.containsKey('tunMode')) {
      return _parseBool(json['tunMode'], false);
    }
    if (json.containsKey('enableSystemProxy')) {
      return !_parseBool(json['enableSystemProxy'], true);
    }
    return false;
  }

  static ProxyMode _parseProxyMode(String? mode) {
    switch (mode) {
      case 'global':
        return ProxyMode.global;
      default:
        return ProxyMode.rule;
    }
  }
}

String _parseLatencyTestUrl(Object? value) {
  final url = value?.toString().trim();
  if (url == null ||
      url.isEmpty ||
      url == 'http://www.gstatic.com/generate_204') {
    return AppConstants.defaultLatencyTestUrl;
  }
  return url;
}

/// 代理模式枚举
enum ProxyMode {
  global('全局模式', 'Global'),
  rule('规则模式', 'Rule');

  final String chineseName;
  final String englishName;
  const ProxyMode(this.chineseName, this.englishName);
}
