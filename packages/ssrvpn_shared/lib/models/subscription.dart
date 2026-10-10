import '../utils/subscription_usage_policy.dart';
import 'subscription_usage.dart';

class Subscription {
  Subscription({
    required this.id,
    required String name,
    required this.url,
    this.lastUpdate,
    this.enabled = true,
    this.autoUpdate = true,
    SubscriptionUsage? usage,
    this.refreshViaProxy = false,
    this.disabledSourceYaml,
    this.disabledNamesTrusted = false,
  })  : _name = name,
        _usage = usage {
    if (!_allowsUsage) _usage = null;
  }

  final String id;
  String _name;
  String get name => _allowsUsage ? _name : 'vip.ssrvpn.vip';
  set name(String value) => _name = value;
  String url;
  DateTime? lastUpdate;
  bool enabled;
  bool autoUpdate;
  bool refreshViaProxy;
  SubscriptionUsage? _usage;
  SubscriptionUsage? get usage => _allowsUsage ? _usage : null;
  set usage(SubscriptionUsage? value) => _usage = _allowsUsage ? value : null;

  // Repeated UI/serialization reads must not normalize a large URL each time.
  // The cache belongs to this object and follows its mutable source URL.
  ({String url, bool allowed})? _usagePolicy;
  bool get _allowsUsage {
    if (_usagePolicy?.url != url) {
      _usagePolicy = (url: url, allowed: SubscriptionUsagePolicy.allows(url));
    }
    return _usagePolicy!.allowed;
  }

  /// Offline source retained only while this subscription is disabled.
  String? disabledSourceYaml;

  /// Set only when the app captures names from its committed runtime cache.
  bool disabledNamesTrusted;

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        lastUpdate: _parseDate(json['lastUpdate']),
        usage: SubscriptionUsagePolicy.allows(json['url']?.toString() ?? '')
            ? SubscriptionUsage.fromJson(json['usage'])
            : null,
        refreshViaProxy: json['refreshViaProxy'] == true,
        disabledSourceYaml: json['disabledSourceYaml'] is String
            ? json['disabledSourceYaml'] as String
            : null,
        disabledNamesTrusted: json['disabledNamesTrusted'] == true,
        enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
        autoUpdate:
            json['autoUpdate'] is bool ? json['autoUpdate'] as bool : true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'lastUpdate': lastUpdate?.toIso8601String(),
        'enabled': enabled,
        'autoUpdate': autoUpdate,
        'refreshViaProxy': refreshViaProxy,
        if (usage != null) 'usage': usage!.toJson(),
        if (disabledSourceYaml != null)
          'disabledSourceYaml': disabledSourceYaml,
        if (disabledSourceYaml != null && disabledNamesTrusted)
          'disabledNamesTrusted': true,
      };

  static DateTime? _parseDate(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }
}

class DuplicateSubscriptionUrlException implements Exception {
  const DuplicateSubscriptionUrlException();

  @override
  String toString() => '该订阅链接已存在';
}

class CrossSubscriptionProxyException extends FormatException {
  const CrossSubscriptionProxyException()
      : super('链式代理入口必须属于同一订阅；共享节点的入口须存在于全部所属订阅');
}
