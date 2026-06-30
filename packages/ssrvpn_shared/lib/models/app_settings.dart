import '../utils/force_proxy_site_policy.dart';

/// 应用设置数据模型 - 跨平台共享
///
/// 包含所有平台通用的设置字段
/// 平台特定的设置可以通过继承或组合方式扩展
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

  // ── 系统代理 / 托盘 ──
  bool minimizeToTray;
  bool startOnBoot;
  bool startMinimized;
  bool closeToTray;

  // ── 外观 ──
  bool darkMode;

  // ── 订阅 ──
  bool autoUpdateSubscription;
  int updateIntervalHours;

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
    this.enableTun = false,
    this.tunStack = 'gvisor',
    this.minimizeToTray = true,
    this.startOnBoot = false,
    this.startMinimized = false,
    this.closeToTray = false,
    this.darkMode = true,
    this.autoUpdateSubscription = true,
    this.updateIntervalHours = 24,
    this.latencyTestUrl = 'http://www.gstatic.com/generate_204',
    this.lastSelectedNodeName,
    this.latencyTestTimeout = 5000,
    Iterable<Object?>? forceProxySites,
  }) : forceProxySites = normalizeForceProxySites(forceProxySites);

  /// 从 JSON 反序列化
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      proxyPort: json['proxyPort'] as int? ?? 7890,
      socksPort: json['socksPort'] as int? ?? 7891,
      apiPort: json['apiPort'] as int? ?? 9090,
      apiSecret: json['apiSecret'] as String? ?? '',
      proxyMode: ProxyMode.values.firstWhere(
        (e) => e.name == json['proxyMode'],
        orElse: () => ProxyMode.rule,
      ),
      enableTun: json['enableTun'] as bool? ?? false,
      tunStack: json['tunStack'] as String? ?? 'gvisor',
      minimizeToTray: json['minimizeToTray'] as bool? ?? true,
      startOnBoot: json['startOnBoot'] as bool? ?? false,
      startMinimized: json['startMinimized'] as bool? ?? false,
      closeToTray: _parseBool(json['closeToTray'], false),
      darkMode: _parseBool(json['darkMode'], true),
      autoUpdateSubscription: _parseBool(json['autoUpdateSubscription'], true),
      updateIntervalHours: json['updateIntervalHours'] as int? ?? 24,
      latencyTestUrl: json['latencyTestUrl'] as String? ??
          'http://www.gstatic.com/generate_204',
      lastSelectedNodeName: json['lastSelectedNodeName'] as String?,
      latencyTestTimeout: json['latencyTestTimeout'] as int? ?? 5000,
      forceProxySites: json['forceProxySites'] is Iterable
          ? json['forceProxySites'] as Iterable
          : null,
    );
  }

  /// 序列化为 JSON
  Map<String, dynamic> toJson() {
    return {
      'proxyPort': proxyPort,
      'socksPort': socksPort,
      'apiPort': apiPort,
      'apiSecret': apiSecret,
      'proxyMode': proxyMode.name,
      'enableTun': enableTun,
      'tunStack': tunStack,
      'minimizeToTray': minimizeToTray,
      'startOnBoot': startOnBoot,
      'startMinimized': startMinimized,
      'closeToTray': closeToTray,
      'darkMode': darkMode,
      'autoUpdateSubscription': autoUpdateSubscription,
      'updateIntervalHours': updateIntervalHours,
      'latencyTestUrl': latencyTestUrl,
      'lastSelectedNodeName': lastSelectedNodeName,
      'latencyTestTimeout': latencyTestTimeout,
      'forceProxySites': forceProxySites,
    };
  }

  /// 复制并修改
  AppSettings copyWith({
    int? proxyPort,
    int? socksPort,
    int? apiPort,
    String? apiSecret,
    ProxyMode? proxyMode,
    bool? enableTun,
    String? tunStack,
    bool? minimizeToTray,
    bool? startOnBoot,
    bool? startMinimized,
    bool? closeToTray,
    bool? darkMode,
    bool? autoUpdateSubscription,
    int? updateIntervalHours,
    String? latencyTestUrl,
    String? lastSelectedNodeName,
    int? latencyTestTimeout,
    Iterable<Object?>? forceProxySites,
  }) {
    return AppSettings(
      proxyPort: proxyPort ?? this.proxyPort,
      socksPort: socksPort ?? this.socksPort,
      apiPort: apiPort ?? this.apiPort,
      apiSecret: apiSecret ?? this.apiSecret,
      proxyMode: proxyMode ?? this.proxyMode,
      enableTun: enableTun ?? this.enableTun,
      tunStack: tunStack ?? this.tunStack,
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      startOnBoot: startOnBoot ?? this.startOnBoot,
      startMinimized: startMinimized ?? this.startMinimized,
      closeToTray: closeToTray ?? this.closeToTray,
      darkMode: darkMode ?? this.darkMode,
      autoUpdateSubscription:
          autoUpdateSubscription ?? this.autoUpdateSubscription,
      updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
      latencyTestUrl: latencyTestUrl ?? this.latencyTestUrl,
      lastSelectedNodeName: lastSelectedNodeName ?? this.lastSelectedNodeName,
      latencyTestTimeout: latencyTestTimeout ?? this.latencyTestTimeout,
      forceProxySites: forceProxySites ?? this.forceProxySites,
    );
  }

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
        other.minimizeToTray == minimizeToTray &&
        other.startOnBoot == startOnBoot &&
        other.startMinimized == startMinimized &&
        other.closeToTray == closeToTray &&
        other.darkMode == darkMode &&
        other.autoUpdateSubscription == autoUpdateSubscription &&
        other.updateIntervalHours == updateIntervalHours &&
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
      minimizeToTray,
      startOnBoot,
      startMinimized,
      closeToTray,
      darkMode,
      autoUpdateSubscription,
      updateIntervalHours,
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

  static List<String> normalizeForceProxySites(Iterable<Object?>? sites) {
    return ForceProxySitePolicy.normalize(
      sites,
      limit: forceProxySiteLimit,
    );
  }

  static String? extractForceProxyHost(String site) {
    return ForceProxySitePolicy.extractHost(site);
  }

  static bool _parseBool(Object? value, bool fallback) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is String) return value == 'true';
    if (value is int) return value != 0;
    return fallback;
  }
}

/// 代理模式枚举
enum ProxyMode {
  rule, // 规则模式
  global, // 全局模式
}
