class LogRedactor {
  static String sanitize(Object? value) {
    var message = value?.toString() ?? '';
    message = message.replaceAllMapped(
      RegExp(
        r'\b(authorization)\s*[:=]\s*Bearer\s+[^\s,;]+',
        caseSensitive: false,
      ),
      (match) => '${match[1]}: Bearer ***',
    );
    message = message.replaceAllMapped(
      RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false),
      (_) => 'Bearer ***',
    );
    message = message.replaceAllMapped(
      RegExp(
        r'''\b(apiSecret|secret|password|token)\s*[:=]\s*["']?[^\s,;"']+["']?''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}: ***',
    );
    return message;
  }
}
