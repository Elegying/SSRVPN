class LogRedactor {
  static const _sensitiveKeyPattern =
      r'apiSecret|api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|secret|password|token';

  static String sanitize(Object? value) {
    var message = value?.toString() ?? '';

    message = message.replaceAllMapped(
      RegExp(
        r'([a-z][a-z0-9+.-]*://)([^/\s:@?#]+):([^/\s@?#]+)@',
        caseSensitive: false,
      ),
      (match) => '${match[1]}***:***@',
    );

    message = message.replaceAllMapped(
      RegExp(
        '([?&#;](?:$_sensitiveKeyPattern)=)([^\\s&#;]+)',
        caseSensitive: false,
      ),
      (match) => '${match[1]}***',
    );

    message = message.replaceAllMapped(
      RegExp(
        '''(["']authorization["']\\s*:\\s*["'])(?:(Bearer|Basic|Token|ApiKey)\\s+)?[^"']+(["'])''',
        caseSensitive: false,
      ),
      (match) {
        final scheme = match[2];
        final prefix = match[1]!;
        final redactedValue = scheme == null ? '***' : '$scheme ***';
        return '$prefix$redactedValue${match[3]}';
      },
    );

    message = message.replaceAllMapped(
      RegExp(
        '''(["'](?:$_sensitiveKeyPattern)["']\\s*:\\s*["'])[^"']+(["'])''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}***${match[2]}',
    );

    message = message.replaceAllMapped(
      RegExp(
        r'''\b(authorization)\s*[:=]\s*(Bearer|Basic|Token|ApiKey)\s+[^\s,;"']+''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}: ${match[2]} ***',
    );
    message = message.replaceAllMapped(
      RegExp(
        r'''\b(authorization)\s*[:=]\s*(?!(?:Bearer|Basic|Token|ApiKey)\b)[^\s,;"']+''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}: ***',
    );
    message = message.replaceAllMapped(
      RegExp(r'''\bBearer\s+[^\s,;"']+''', caseSensitive: false),
      (_) => 'Bearer ***',
    );
    message = message.replaceAllMapped(
      RegExp(
        '''(^|[\\s,{])\\b($_sensitiveKeyPattern)\\s*[:=]\\s*["']?[^\\s,;"']+["']?''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}${match[2]}: ***',
    );
    return message;
  }
}
