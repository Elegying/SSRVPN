import 'package:ssrvpn_shared/utils/force_proxy_site_policy.dart';
import 'package:ssrvpn_shared/models/app_settings.dart' show ProxyMode;

/// 应用设置数据模型 — Android 版本
///
/// 与 macOS 版本功能对齐，Android 特有字段加注释
class AppSettings {
  static const int forceProxySiteLimit = ForceProxySitePolicy.defaultLimit;

  // ── 端口 ──
  int proxyPort; // mixed-port, 默认7890
  int socksPort;
  int apiPort;
  String apiSecret; // API密钥

  // ── 代理模式 ──
  ProxyMode proxyMode;

  // ── TUN / VPN ──
  bool enableTun;
  String tunStack; // gvisor / system / mixed（macOS用，Android用VPN Service替代）

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

  // ── Android 特有 ──
  bool autoConnectOnStartup;
  bool autoCheckUpdate;

  AppSettings({
    this.proxyPort = 7890,
    this.socksPort = 7891,
    this.apiPort = 9090,
    this.apiSecret = '',
    this.proxyMode = ProxyMode.rule,
    bool? enableTun,
    this.tunStack = 'gvisor',
    this.minimizeToTray = false,
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
    this.autoConnectOnStartup = false,
    this.autoCheckUpdate = true,
  })  : enableTun = enableTun ?? false,
        forceProxySites = normalizeForceProxySites(forceProxySites);

  // ── 便捷 getter/setter ──
  String? get lastSelectedNode => lastSelectedNodeName;
  set lastSelectedNode(String? value) => lastSelectedNodeName = value;

  bool get tunMode => enableTun;
  set tunMode(bool value) => enableTun = value;

  bool get enableSystemProxy => !enableTun;
  set enableSystemProxy(bool value) => enableTun = !value;

  AppSettings copyWith({
    int? proxyPort,
    int? socksPort,
    int? apiPort,
    String? apiSecret,
    bool? enableTun,
    bool? enableSystemProxy,
    String? tunStack,
    ProxyMode? proxyMode,
    bool? minimizeToTray,
    bool? startOnBoot,
    bool? startMinimized,
    bool? closeToTray,
    bool? darkMode,
    bool? autoUpdateSubscription,
    int? updateIntervalHours,
    String? latencyTestUrl,
    String? lastSelectedNode,
    String? lastSelectedNodeName,
    int? latencyTestTimeout,
    Iterable<Object?>? forceProxySites,
    bool? autoConnectOnStartup,
    bool? autoCheckUpdate,
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
      lastSelectedNodeName: lastSelectedNodeName ?? lastSelectedNode,
      latencyTestTimeout: latencyTestTimeout ?? this.latencyTestTimeout,
      forceProxySites: forceProxySites,
      autoConnectOnStartup: autoConnectOnStartup ?? this.autoConnectOnStartup,
      autoCheckUpdate: autoCheckUpdate ?? this.autoCheckUpdate,
    );
  }

  Map<String, dynamic> toJson() => {
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
        'autoConnectOnStartup': autoConnectOnStartup,
        'autoCheckUpdate': autoCheckUpdate,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      proxyPort: _parsePort(json['proxyPort'], 7890),
      socksPort: _parsePort(json['socksPort'], 7891),
      apiPort: _parsePort(json['apiPort'], 9090),
      apiSecret: json['apiSecret']?.toString() ?? '',
      proxyMode: _parseProxyMode(json['proxyMode'] as String?),
      enableTun: _parseBool(json['enableTun'], false),
      tunStack: json['tunStack']?.toString() ?? 'gvisor',
      minimizeToTray: _parseBool(json['minimizeToTray'], false),
      startOnBoot: _parseBool(json['startOnBoot'], false),
      startMinimized: _parseBool(json['startMinimized'], false),
      closeToTray: _parseBool(json['closeToTray'], false),
      darkMode: _parseBool(json['darkMode'], true),
      autoUpdateSubscription: _parseBool(json['autoUpdateSubscription'], true),
      updateIntervalHours:
          _parsePositiveInt(json['updateIntervalHours'], 24, min: 1, max: 720),
      latencyTestUrl: json['latencyTestUrl']?.toString() ??
          'http://www.gstatic.com/generate_204',
      lastSelectedNodeName: json['lastSelectedNodeName'] as String?,
      latencyTestTimeout: _parseTimeout(json['latencyTestTimeout'], 5000),
      forceProxySites: json['forceProxySites'] is List
          ? (json['forceProxySites'] as List).map((e) => e?.toString() ?? '')
          : null,
      autoConnectOnStartup: _parseBool(json['autoConnectOnStartup'], false),
      autoCheckUpdate: _parseBool(json['autoCheckUpdate'], true),
    );
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

  static int _parsePositiveInt(
    Object? value,
    int fallback, {
    required int min,
    required int max,
  }) {
    final parsed = int.tryParse(value?.toString() ?? '');
    return parsed != null && parsed >= min && parsed <= max ? parsed : fallback;
  }

  static bool _parseBool(Object? value, bool fallback) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is String) return value == 'true';
    if (value is int) return value != 0;
    return fallback;
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

// ProxyMode 枚举已移至 ssrvpn_shared，通过上方 import 导入
