/// One indivisible, validated account snapshot. Times are Unix seconds on server.
class AccountUsage {
  const AccountUsage({
    required this.usedBytes,
    required this.trafficLimitBytes,
    required this.onlineDevices,
    required this.deviceLimit,
    required this.serverTime,
    required this.trafficObservedAt,
    required this.onlineObservedAt,
    required this.expiresAt,
  });

  final int usedBytes, trafficLimitBytes, onlineDevices, deviceLimit;
  final int serverTime, trafficObservedAt, onlineObservedAt, expiresAt;

  factory AccountUsage.parse(Object? json) {
    Never invalid() => throw const FormatException('Invalid account usage');
    if (json is! Map<String, dynamic> ||
        json['apiVersion'] != 1 ||
        json['apiVersion'] is! int ||
        json.containsKey('error')) {
      invalid();
    }
    final data = json['data'];
    final meta = json['meta'];
    if (data is! Map<String, dynamic> ||
        meta is! Map<String, dynamic> ||
        data['scope'] != 'account' ||
        meta['complete'] != true) {
      invalid();
    }
    int integer(Map<String, dynamic> map, String key) {
      final value = map[key];
      if (value is! int || value < 0 || value > 9223372036854775807) invalid();
      return value;
    }

    final result = AccountUsage(
      usedBytes: integer(data, 'usedBytes'),
      trafficLimitBytes: integer(data, 'trafficLimitBytes'),
      onlineDevices: integer(data, 'onlineDevices'),
      deviceLimit: integer(data, 'deviceLimit'),
      serverTime: integer(meta, 'serverTime'),
      trafficObservedAt: integer(meta, 'trafficObservedAt'),
      onlineObservedAt: integer(meta, 'onlineObservedAt'),
      expiresAt: integer(meta, 'expiresAt'),
    );
    // A full response cannot make observations older than 30 seconds fresh.
    if (result.serverTime <= 0 ||
        result.trafficObservedAt <= 0 ||
        result.onlineObservedAt <= 0 ||
        result.expiresAt <= result.serverTime ||
        result.trafficObservedAt > result.serverTime ||
        result.onlineObservedAt > result.serverTime ||
        result.expiresAt - result.trafficObservedAt > 30 ||
        result.expiresAt - result.onlineObservedAt > 30) {
      invalid();
    }
    return result;
  }
}
