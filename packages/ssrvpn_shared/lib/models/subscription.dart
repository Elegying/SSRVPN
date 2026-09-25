class Subscription {
  Subscription({
    required this.id,
    required this.name,
    required this.url,
    this.lastUpdate,
    this.enabled = true,
    this.autoUpdate = true,
  });

  final String id;
  String name;
  String url;
  DateTime? lastUpdate;
  bool enabled;
  bool autoUpdate;

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        lastUpdate: _parseDate(json['lastUpdate']),
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
