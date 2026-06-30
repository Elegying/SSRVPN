import 'package:ssrvpn_shared/utils/force_proxy_site_policy.dart';
import 'package:ssrvpn_shared/models/app_settings.dart' show ProxyMode;

/// 应用设置模型
class AppSettings {
  static const int forceProxySiteLimit = ForceProxySitePolicy.defaultLimit;

  // 代理端口
  int proxyPort; // mixed-port, 默认7890
  int socksPort; // 默认7891
  int apiPort; // Clash API端口, 默认9090
  String apiSecret; // API密钥

  // 代理模式
  ProxyMode proxyMode;

  // TUN 模式
  bool enableTun; // 是否启用 TUN 模式（macOS 首次启用需要管理员授权）
  String tunStack; // gvisor / system / mixed

  // 桌面端设置
  bool minimizeToTray; // 关闭窗口时最小化到托盘
  bool startWithWindows; // 开机自启（暂未实现）
  bool startOnBoot;
  bool startMinimized;
  bool closeToTray;

  // 主题
  bool darkMode;

  // 订阅自动更新（保留旧 macOS 配置兼容）
  bool autoUpdateSubscription;
  int updateIntervalHours;

  // 延迟测试
  String latencyTestUrl;
  String? lastSelectedNodeName;
  int latencyTestTimeout; // 毫秒
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
    this.tunStack = 'gvisor',
    this.minimizeToTray = true,
    this.startWithWindows = false,
    this.startOnBoot = false,
    this.startMinimized = false,
    this.closeToTray = false,
    this.darkMode = true,
    this.autoUpdateSubscription = true,
    this.updateIntervalHours = 24,
    this.latencyTestUrl = 'http://www.gstatic.com/generate_204',
    String? lastSelectedNodeName,
    String? lastSelectedNode,
    this.latencyTestTimeout = 5000,
    Iterable<Object?>? forceProxySites,
  })  : enableTun =
            enableTun ?? tunMode ?? (enableSystemProxy == false ? true : false),
        lastSelectedNodeName = lastSelectedNodeName ?? lastSelectedNode,
        forceProxySites = normalizeForceProxySites(forceProxySites);

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
    ProxyMode? proxyMode,
    bool? enableTun,
    bool? tunMode,
    bool? enableSystemProxy,
    String? tunStack,
    bool? minimizeToTray,
    bool? startWithWindows,
    bool? startOnBoot,
    bool? startMinimized,
    bool? closeToTray,
    bool? darkMode,
    bool? autoUpdateSubscription,
    int? updateIntervalHours,
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
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      startWithWindows: startWithWindows ?? this.startWithWindows,
      startOnBoot: startOnBoot ?? this.startOnBoot,
      startMinimized: startMinimized ?? this.startMinimized,
      closeToTray: closeToTray ?? this.closeToTray,
      darkMode: darkMode ?? this.darkMode,
      autoUpdateSubscription:
          autoUpdateSubscription ?? this.autoUpdateSubscription,
      updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
      latencyTestUrl: latencyTestUrl ?? this.latencyTestUrl,
      lastSelectedNodeName:
          lastSelectedNodeName ?? lastSelectedNode ?? this.lastSelectedNodeName,
      latencyTestTimeout: latencyTestTimeout ?? this.latencyTestTimeout,
      forceProxySites: forceProxySites ?? this.forceProxySites,
    );
  }

  Map<String, dynamic> toJson() => {
        'proxyPort': proxyPort,
        'socksPort': socksPort,
        'apiPort': apiPort,
        'apiSecret': apiSecret,
        'proxyMode': proxyMode.name,
        'enableTun': enableTun,
        'tunMode': enableTun,
        'enableSystemProxy': !enableTun,
        'tunStack': tunStack,
        'minimizeToTray': minimizeToTray,
        'startWithWindows': startWithWindows,
        'startOnBoot': startOnBoot,
        'startMinimized': startMinimized,
        'closeToTray': closeToTray,
        'darkMode': darkMode,
        'autoUpdateSubscription': autoUpdateSubscription,
        'updateIntervalHours': updateIntervalHours,
        'latencyTestUrl': latencyTestUrl,
        'lastSelectedNodeName': lastSelectedNodeName,
        'lastSelectedNode': lastSelectedNodeName,
        'latencyTestTimeout': latencyTestTimeout,
        'forceProxySites': forceProxySites,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        proxyPort: _parsePort(json['proxyPort'], 7890),
        socksPort: _parsePort(json['socksPort'], 7891),
        apiPort: _parsePort(json['apiPort'], 9090),
        apiSecret: json['apiSecret'] as String? ?? '',
        proxyMode: _parseProxyMode(json['proxyMode'] as String?),
        enableTun: json['enableTun'] as bool? ?? json['tunMode'] as bool?,
        tunStack: json['tunStack'] as String? ?? 'gvisor',
        enableSystemProxy: json['enableSystemProxy'] as bool?,
        minimizeToTray: json['minimizeToTray'] as bool? ?? true,
        startWithWindows: json['startWithWindows'] as bool? ?? false,
        startOnBoot: json['startOnBoot'] as bool? ?? false,
        startMinimized: json['startMinimized'] as bool? ?? false,
        closeToTray: json['closeToTray'] as bool? ?? false,
        darkMode: json['darkMode'] as bool? ?? true,
        autoUpdateSubscription: json['autoUpdateSubscription'] as bool? ?? true,
        updateIntervalHours: _parsePositiveInt(
          json['updateIntervalHours'],
          24,
          min: 1,
          max: 24 * 30,
        ),
        lastSelectedNodeName: json['lastSelectedNodeName'] as String? ??
            json['lastSelectedNode'] as String?,
        latencyTestUrl: json['latencyTestUrl'] as String? ??
            'http://www.gstatic.com/generate_204',
        latencyTestTimeout: _parseTimeout(json['latencyTestTimeout'], 5000),
        forceProxySites: json['forceProxySites'] is Iterable
            ? json['forceProxySites'] as Iterable
            : null,
      );

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
