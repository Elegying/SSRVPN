class Subscription {
  Subscription({
    required this.id,
    required this.name,
    required this.url,
    DateTime? lastUpdate,
    this.enabled = true,
    this.autoUpdate = true,
  }) : lastUpdate = lastUpdate;

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
