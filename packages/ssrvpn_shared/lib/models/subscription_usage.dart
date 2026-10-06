/// Provider-reported account snapshot, independent of local session traffic.
class SubscriptionUsage {
  const SubscriptionUsage({
    this.upload,
    this.download,
    this.total,
    this.expire,
    required this.updatedAt,
  });
  final int? upload, download, total, expire;
  final DateTime updatedAt;
  int? get used =>
      upload != null && download != null ? upload! + download! : null;
  bool get hasData => used != null || expire != null;

  static int? _bytes(Object? value) {
    final parsed = value is int ? value : null;
    return parsed != null && parsed >= 0 && parsed <= 0x3fffffffffffffff
        ? parsed
        : null;
  }

  static int? _expiry(Object? value) {
    final parsed = _bytes(value);
    return parsed != null && parsed <= 253402214400 ? parsed : null;
  }

  static SubscriptionUsage? fromJson(Object? value) {
    if (value is! Map) return null;
    final time = value['updatedAt'];
    final updated = time is String ? DateTime.tryParse(time) : null;
    if (updated == null) return null;
    final result = SubscriptionUsage(
        upload: _bytes(value['upload']),
        download: _bytes(value['download']),
        total: _bytes(value['total']),
        expire: _expiry(value['expire']),
        updatedAt: updated);
    return result.hasData ? result : null;
  }

  static SubscriptionUsage? fromHeaders(Map<String, String> headers,
      {required DateTime now}) {
    final matching = headers.entries
        .where((e) => e.key.toLowerCase() == 'subscription-userinfo')
        .toList();
    if (matching.length != 1 || matching.single.value.length > 8192) {
      return null;
    }
    final values = <String, Object?>{
      'updatedAt': now.toUtc().toIso8601String()
    };
    final seen = <String>{};
    for (final part in matching.single.value.split(';')) {
      final equals = part.indexOf('=');
      if (equals < 0) continue;
      final key = part.substring(0, equals).trim().toLowerCase();
      if (!const {'upload', 'download', 'total', 'expire'}.contains(key)) {
        continue;
      }
      final text = part.substring(equals + 1).trim();
      values[key] = seen.add(key) && RegExp(r'^\d{1,19}$').hasMatch(text)
          ? int.tryParse(text)
          : null;
    }
    return fromJson(values);
  }

  Map<String, Object?> toJson() => {
        'upload': upload,
        'download': download,
        'total': total,
        'expire': expire,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };
}
