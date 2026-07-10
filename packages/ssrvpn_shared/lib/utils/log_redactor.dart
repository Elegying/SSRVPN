class LogRedactor {
  static const int maxInputCharacters = 4 * 1024;
  static const _truncatedMarker = '\n... log entry truncated ...';
  static const _sensitiveKeyPattern =
      r'apiSecret|api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|secret|password|token';
  static const _proxyUriSchemes = {
    'ss',
    'ssr',
    'trojan',
    'vless',
    'vmess',
    'hysteria2',
    'hy2',
    'tuic',
    'anytls',
  };
  static final _proxyUriPattern = RegExp(
    r"""\b(ss|ssr|trojan|vless|vmess|hysteria2|hy2|tuic|anytls)://[^\s<>"']+""",
    caseSensitive: false,
  );
  static final _urlUserInfoPattern = RegExp(
    r'([a-z][a-z0-9+.-]*://)([^/\s:@?#]+):([^/\s@?#]+)@',
    caseSensitive: false,
  );
  static final _queryCredentialPattern = RegExp(
    '([?&#;](?:$_sensitiveKeyPattern)=)([^\\s&#;]+)',
    caseSensitive: false,
  );
  static final _jsonAuthorizationPattern = RegExp(
    '''(["']authorization["']\\s*:\\s*["'])(?:(Bearer|Basic|Token|ApiKey)\\s+)?[^"']+(["'])''',
    caseSensitive: false,
  );
  static final _jsonCredentialPattern = RegExp(
    '''(["'](?:$_sensitiveKeyPattern)["']\\s*:\\s*["'])[^"']+(["'])''',
    caseSensitive: false,
  );
  static final _authorizationSchemePattern = RegExp(
    r'''\b(authorization)\s*[:=]\s*(Bearer|Basic|Token|ApiKey)\s+[^\s,;"']+''',
    caseSensitive: false,
  );
  static final _authorizationValuePattern = RegExp(
    r'''\b(authorization)\s*[:=]\s*(?!(?:Bearer|Basic|Token|ApiKey)\b)[^\s,;"']+''',
    caseSensitive: false,
  );
  static final _bearerPattern = RegExp(
    r'''\bBearer\s+[^\s,;"']+''',
    caseSensitive: false,
  );
  static final _credentialAssignmentPattern = RegExp(
    '''(^|[\\s,{])\\b($_sensitiveKeyPattern)\\s*[:=]\\s*["']?[^\\s,;"']+["']?''',
    caseSensitive: false,
  );

  static String sanitize(Object? value) {
    var message = value?.toString() ?? '';
    final wasTruncated = message.length > maxInputCharacters;
    if (wasTruncated) {
      var end = maxInputCharacters;
      if (end < message.length &&
          end > 0 &&
          _isHighSurrogate(message.codeUnitAt(end - 1)) &&
          _isLowSurrogate(message.codeUnitAt(end))) {
        end--;
      }
      message = message.substring(0, end);
    }

    message = message.replaceAllMapped(
      _proxyUriPattern,
      (match) => '${match[1]!.toLowerCase()}://***',
    );

    message = message.replaceAllMapped(
      _urlUserInfoPattern,
      (match) => '${match[1]}***:***@',
    );

    message = message.replaceAllMapped(
      _queryCredentialPattern,
      (match) => '${match[1]}***',
    );

    message = message.replaceAllMapped(
      _jsonAuthorizationPattern,
      (match) {
        final scheme = match[2];
        final prefix = match[1]!;
        final redactedValue = scheme == null ? '***' : '$scheme ***';
        return '$prefix$redactedValue${match[3]}';
      },
    );

    message = message.replaceAllMapped(
      _jsonCredentialPattern,
      (match) => '${match[1]}***${match[2]}',
    );

    message = message.replaceAllMapped(
      _authorizationSchemePattern,
      (match) => '${match[1]}: ${match[2]} ***',
    );
    message = message.replaceAllMapped(
      _authorizationValuePattern,
      (match) => '${match[1]}: ***',
    );
    message = message.replaceAllMapped(_bearerPattern, (_) => 'Bearer ***');
    message = message.replaceAllMapped(
      _credentialAssignmentPattern,
      (match) => '${match[1]}${match[2]}: ***',
    );
    return wasTruncated ? '$message$_truncatedMarker' : message;
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  static String subscriptionUrlForDisplay(Object? value) {
    var text = value?.toString().trim() ?? '';
    if (text.length > maxInputCharacters) {
      text = text.substring(0, maxInputCharacters);
    }
    final uri = Uri.tryParse(text);
    if (uri != null && uri.hasScheme) {
      final scheme = uri.scheme.toLowerCase();
      if (_proxyUriSchemes.contains(scheme)) {
        return '$scheme://***';
      }
      if (scheme == 'http' || scheme == 'https') {
        final host = uri.host.isEmpty ? '***' : uri.host;
        return '$scheme://$host/***';
      }
    }
    return sanitize(text);
  }
}
