class ProxyNode {
  ProxyNode({
    required this.name,
    required this.type,
    required this.server,
    required this.port,
    this.group = '默认',
    this.latency,
    this.isOnline = true,
    this.lastLatencyTest,
    Map<String, dynamic>? extra,
  }) : extra = Map<String, dynamic>.from(extra ?? const {});

  final String name;
  final String type;
  final String server;
  final int port;
  final String group;
  int? latency;
  bool isOnline;
  DateTime? lastLatencyTest;
  final Map<String, dynamic> extra;

  factory ProxyNode.fromJson(Map<String, dynamic> json) {
    final extra = Map<String, dynamic>.from(json);
    final nestedExtra = json['extra'];
    if (nestedExtra is Map) {
      extra.addAll(
        nestedExtra.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    return ProxyNode(
      name: json['name']?.toString() ?? 'Unknown',
      type: json['type']?.toString() ?? 'ss',
      server: json['server']?.toString() ?? '',
      port: _parsePort(json['port']),
      group: json['group']?.toString() ?? '默认',
      latency: _parseNullableInt(json['latency']),
      isOnline: json['isOnline'] is bool ? json['isOnline'] as bool : true,
      lastLatencyTest: _parseDate(json['lastLatencyTest']),
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        'server': server,
        'port': port,
        'group': group,
        'latency': latency,
        'isOnline': isOnline,
        'lastLatencyTest': lastLatencyTest?.toIso8601String(),
        'extra': extra,
      };

  ProxyNode copyWith({
    String? name,
    String? type,
    String? server,
    int? port,
    String? group,
    int? latency,
    bool? isOnline,
    DateTime? lastLatencyTest,
    Map<String, dynamic>? extra,
  }) {
    return ProxyNode(
      name: name ?? this.name,
      type: type ?? this.type,
      server: server ?? this.server,
      port: port ?? this.port,
      group: group ?? this.group,
      latency: latency ?? this.latency,
      isOnline: isOnline ?? this.isOnline,
      lastLatencyTest: lastLatencyTest ?? this.lastLatencyTest,
      extra: extra ?? this.extra,
    );
  }

  int get latencyLevel {
    final value = latency;
    if (value == null || value <= 0) return 2;
    if (value < 200) return 0;
    if (value < 500) return 1;
    return 2;
  }

  String get latencyText {
    final value = latency;
    if (value == null || value <= 0) return '超时';
    return '${value}ms';
  }

  bool get isTimedOut {
    final value = latency;
    return value == null || value <= 0 || value >= 65535;
  }

  int get effectiveLatency => isTimedOut ? 65535 : latency!;

  static int _parsePort(Object? value) {
    final parsed = int.tryParse(value?.toString() ?? '');
    return parsed == null || parsed < 0 ? 0 : parsed;
  }

  static int? _parseNullableInt(Object? value) {
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  static DateTime? _parseDate(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }
}
