import 'package:ssrvpn_shared/utils/force_proxy_site_policy.dart';

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

  // TUN 模式（Windows 特有）
  bool enableTun; // 是否启用 TUN 模式（需管理员权限）
  String tunStack; // gvisor / system / mixed

  // Windows 特有设置
  bool minimizeToTray; // 关闭窗口时最小化到托盘
  bool startWithWindows; // 开机自启（暂未实现）

  // 主题
  bool darkMode;

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
    this.enableTun = false, // 默认关闭 TUN（需要管理员权限）
    this.tunStack = 'gvisor',
    this.minimizeToTray = true,
    this.startWithWindows = false,
    this.darkMode = true,
    this.latencyTestUrl = 'http://www.gstatic.com/generate_204',
    this.lastSelectedNodeName,
    this.latencyTestTimeout = 5000,
    Iterable<Object?>? forceProxySites,
  }) : forceProxySites = normalizeForceProxySites(forceProxySites);

  AppSettings copyWith({
    int? proxyPort,
    int? socksPort,
    int? apiPort,
    String? apiSecret,
    ProxyMode? proxyMode,
    bool? enableTun,
    String? tunStack,
    bool? minimizeToTray,
    bool? startWithWindows,
    bool? darkMode,
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
      startWithWindows: startWithWindows ?? this.startWithWindows,
      darkMode: darkMode ?? this.darkMode,
      latencyTestUrl: latencyTestUrl ?? this.latencyTestUrl,
      lastSelectedNodeName: lastSelectedNodeName ?? this.lastSelectedNodeName,
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
        'tunStack': tunStack,
        'minimizeToTray': minimizeToTray,
        'startWithWindows': startWithWindows,
        'darkMode': darkMode,
        'latencyTestUrl': latencyTestUrl,
        'lastSelectedNodeName': lastSelectedNodeName,
        'latencyTestTimeout': latencyTestTimeout,
        'forceProxySites': forceProxySites,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        proxyPort: _parsePort(json['proxyPort'], 7890),
        socksPort: _parsePort(json['socksPort'], 7891),
        apiPort: _parsePort(json['apiPort'], 9090),
        apiSecret: json['apiSecret'] as String? ?? '',
        proxyMode: _parseProxyMode(json['proxyMode'] as String?),
        enableTun: json['enableTun'] as bool? ?? false,
        tunStack: json['tunStack'] as String? ?? 'gvisor',
        minimizeToTray: json['minimizeToTray'] as bool? ?? true,
        startWithWindows: json['startWithWindows'] as bool? ?? false,
        darkMode: json['darkMode'] as bool? ?? true,
        lastSelectedNodeName: json['lastSelectedNodeName'] as String?,
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

  static ProxyMode _parseProxyMode(String? mode) {
    switch (mode) {
      case 'global':
        return ProxyMode.global;
      default:
        return ProxyMode.rule;
    }
  }
}

/// 代理模式枚举
enum ProxyMode {
  global('全局模式', 'Global'),
  rule('规则模式', 'Rule');

  final String chineseName;
  final String englishName;
  const ProxyMode(this.chineseName, this.englishName);
}
