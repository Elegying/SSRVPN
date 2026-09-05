import 'dart:io';

import 'proxy_node_usage_policy.dart';

class LogRedactor {
  static const int maxInputCharacters = 4 * 1024;
  static const _truncatedMarker = '\n... log entry truncated ...';
  static const _sensitiveKeyPattern =
      r'apiSecret|api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|secret|password|token|psk|auth(?:[_-]?str)?|uuid';
  static final _proxyUriSchemes =
      ProxyNodeUsagePolicy.nodeUriSchemes.difference(const {'http', 'https'});
  static final _proxyUriPattern = RegExp(
    '\\b(${_proxyUriSchemes.map(RegExp.escape).join('|')})'
    r'''://[^\s<>"']+''',
    caseSensitive: false,
  );
  static final _httpUrlPattern = RegExp(
    r'''(https?)://[^\s<>"']+''',
    caseSensitive: false,
  );
  static final _ipv4Pattern = RegExp(
    r'(^|[^0-9])((?:[0-9]{1,3}\.){3}[0-9]{1,3})(?![0-9])',
  );
  static final _bracketedIpv6Pattern = RegExp(r'\[([0-9A-Fa-f:.]+)\]');
  static final _ipv6CandidatePattern = RegExp(
    r'(^|[^0-9A-Fa-f:.])([0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*)(?=$|[^0-9A-Fa-f:.])',
  );
  static final _urlUserInfoPattern = RegExp(
    r'([a-z][a-z0-9+.-]*://)([^/\s:@?#]+):([^/\s@?#]+)@',
    caseSensitive: false,
  );
  static final _queryCredentialPattern = RegExp(
    '([?&#;](?:$_sensitiveKeyPattern)=)([^\\s&#;]+)',
    caseSensitive: false,
  );
  static final _jsonDoubleAuthorizationPattern = RegExp(
    '''("authorization"\\s*:\\s*")(?:(Bearer|Basic|Token|ApiKey)\\s+)?(?:\\\\.|[^"\\\\])+(")''',
    caseSensitive: false,
  );
  static final _jsonSingleAuthorizationPattern = RegExp(
    "('authorization'\\s*:\\s*')(?:(Bearer|Basic|Token|ApiKey)\\s+)?(?:\\\\.|[^'\\\\])+(')",
    caseSensitive: false,
  );
  static final _jsonDoubleCredentialPattern = RegExp(
    '''("(?:$_sensitiveKeyPattern)"\\s*:\\s*")(?:\\\\.|[^"\\\\])+(")''',
    caseSensitive: false,
  );
  static final _jsonSingleCredentialPattern = RegExp(
    "('(?:$_sensitiveKeyPattern)'\\s*:\\s*')(?:\\\\.|[^'\\\\])+(')",
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
  static final _doubleQuotedAuthorizationAssignmentPattern = RegExp(
    '''(^|[\\s,{;\\[])\\b(authorization)\\b\\s*[:=]\\s*"(?:\\\\.|[^"\\\\])*"''',
    caseSensitive: false,
  );
  static final _singleQuotedAuthorizationAssignmentPattern = RegExp(
    "(^|[\\s,{;\\[])\\b(authorization)\\b\\s*[:=]\\s*'(?:\\\\.|[^'\\\\])*'",
    caseSensitive: false,
  );
  static final _unterminatedDoubleQuotedAuthorizationAssignmentPattern = RegExp(
    '''(^|[\\s,{;\\[])\\b(authorization)\\b\\s*[:=]\\s*"(?:\\\\.|[^"\\\\])*\$''',
    caseSensitive: false,
  );
  static final _unterminatedSingleQuotedAuthorizationAssignmentPattern = RegExp(
    "(^|[\\s,{;\\[])\\b(authorization)\\b\\s*[:=]\\s*'(?:\\\\.|[^'\\\\])*\$",
    caseSensitive: false,
  );
  static final _unterminatedDoubleQuotedJsonAuthorizationPattern = RegExp(
    '''(^|[\\s,{;\\[])["']\\b(authorization)\\b["']\\s*:\\s*"(?:\\\\.|[^"\\\\])*\$''',
    caseSensitive: false,
  );
  static final _unterminatedSingleQuotedJsonAuthorizationPattern = RegExp(
    "(^|[\\s,{;\\[])[\"']\\b(authorization)\\b[\"']\\s*:\\s*'(?:\\\\.|[^'\\\\])*\$",
    caseSensitive: false,
  );
  static final _doubleQuotedCredentialAssignmentPattern = RegExp(
    '''(^|[\\s,{;\\[])\\b($_sensitiveKeyPattern)\\s*[:=]\\s*"(?:\\\\.|[^"\\\\])*"''',
    caseSensitive: false,
  );
  static final _singleQuotedCredentialAssignmentPattern = RegExp(
    "(^|[\\s,{;\\[])\\b($_sensitiveKeyPattern)\\s*[:=]\\s*'(?:\\\\.|[^'\\\\])*'",
    caseSensitive: false,
  );
  static final _unterminatedDoubleQuotedCredentialAssignmentPattern = RegExp(
    '''(^|[\\s,{;\\[])\\b($_sensitiveKeyPattern)\\s*[:=]\\s*"(?:\\\\.|[^"\\\\])*\$''',
    caseSensitive: false,
  );
  static final _unterminatedSingleQuotedCredentialAssignmentPattern = RegExp(
    "(^|[\\s,{;\\[])\\b($_sensitiveKeyPattern)\\s*[:=]\\s*'(?:\\\\.|[^'\\\\])*\$",
    caseSensitive: false,
  );
  static final _unterminatedDoubleQuotedJsonCredentialPattern = RegExp(
    '''(^|[\\s,{;\\[])["']\\b($_sensitiveKeyPattern)\\b["']\\s*:\\s*"(?:\\\\.|[^"\\\\])*\$''',
    caseSensitive: false,
  );
  static final _unterminatedSingleQuotedJsonCredentialPattern = RegExp(
    "(^|[\\s,{;\\[])[\"']\\b($_sensitiveKeyPattern)\\b[\"']\\s*:\\s*'(?:\\\\.|[^'\\\\])*\$",
    caseSensitive: false,
  );
  static final _credentialAssignmentPattern = RegExp(
    '''(^|[\\s,{;\\[])\\b($_sensitiveKeyPattern)\\s*[:=]\\s*["']?[^\\s,;"']+["']?''',
    caseSensitive: false,
  );
  static final _yamlBlockCredentialPattern = RegExp(
    '^([ \\t]*)\\b(authorization|$_sensitiveKeyPattern)\\b'
    r'\s*:\s*[>|][+-]?[^\r\n]*'
    r'(?:(?:\r\n|\n)(?:\1[ \t]+[^\r\n]*|[ \t]*(?=\r?$)))*',
    caseSensitive: false,
    multiLine: true,
  );
  static final _unixHomePattern = RegExp(
    r'/(Users|home)/[^/\r\n]+(?=/|$)',
  );
  static final _windowsHomePattern = RegExp(
    r'\b([A-Za-z]:\\Users\\)[^\\\r\n]+(?=\\|$)',
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

    message = message.replaceAllMapped(_httpUrlPattern, (match) {
      final scheme = match[1]!.toLowerCase();
      final uri = Uri.tryParse(match[0]!);
      final rawHost = uri?.host.trim() ?? '';
      final host = rawHost.isEmpty
          ? '***'
          : rawHost.contains(':')
              ? '[$rawHost]'
              : rawHost;
      final port = uri != null && uri.hasPort ? ':${uri.port}' : '';
      return '$scheme://$host$port/***';
    });

    message = message.replaceAllMapped(
      _urlUserInfoPattern,
      (match) => '${match[1]}***:***@',
    );

    message = message.replaceAllMapped(
      _queryCredentialPattern,
      (match) => '${match[1]}***',
    );

    message = message.replaceAllMapped(
      _yamlBlockCredentialPattern,
      (match) => '${match[1]}${match[2]}: ***',
    );

    for (final pattern in [
      _jsonDoubleAuthorizationPattern,
      _jsonSingleAuthorizationPattern,
    ]) {
      message = message.replaceAllMapped(pattern, (match) {
        final scheme = match[2];
        final redactedValue = scheme == null ? '***' : '$scheme ***';
        return '${match[1]}$redactedValue${match[3]}';
      });
    }
    for (final pattern in [
      _jsonDoubleCredentialPattern,
      _jsonSingleCredentialPattern,
    ]) {
      message = message.replaceAllMapped(
        pattern,
        (match) => '${match[1]}***${match[2]}',
      );
    }

    for (final pattern in [
      _doubleQuotedAuthorizationAssignmentPattern,
      _singleQuotedAuthorizationAssignmentPattern,
      _unterminatedDoubleQuotedAuthorizationAssignmentPattern,
      _unterminatedSingleQuotedAuthorizationAssignmentPattern,
      _unterminatedDoubleQuotedJsonAuthorizationPattern,
      _unterminatedSingleQuotedJsonAuthorizationPattern,
      _doubleQuotedCredentialAssignmentPattern,
      _singleQuotedCredentialAssignmentPattern,
      _unterminatedDoubleQuotedCredentialAssignmentPattern,
      _unterminatedSingleQuotedCredentialAssignmentPattern,
      _unterminatedDoubleQuotedJsonCredentialPattern,
      _unterminatedSingleQuotedJsonCredentialPattern,
    ]) {
      message = message.replaceAllMapped(
        pattern,
        (match) => '${match[1]}${match[2]}: ***',
      );
    }
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
    message = message.replaceAllMapped(
      _unixHomePattern,
      (match) => '/${match[1]}/***',
    );
    message = message.replaceAllMapped(
      _windowsHomePattern,
      (match) => '${match[1]}***',
    );
    message = message.replaceAllMapped(_ipv4Pattern, (match) {
      final address = match[2]!;
      final replacement =
          _isPublicIpv4(address) ? '[public-ip-redacted]' : address;
      return '${match[1]}$replacement';
    });
    message = message.replaceAllMapped(_bracketedIpv6Pattern, (match) {
      final address = match[1]!;
      return _isPublicIpv6(address) ? '[public-ip-redacted]' : match[0]!;
    });
    message = message.replaceAllMapped(_ipv6CandidatePattern, (match) {
      final candidate = match[2]!;
      var addressEnd = candidate.length;
      while (addressEnd > 0 && candidate.codeUnitAt(addressEnd - 1) == 0x2e) {
        addressEnd--;
      }
      final address = candidate.substring(0, addressEnd);
      final punctuation = candidate.substring(addressEnd);
      final replacement =
          _isPublicIpv6(address) ? '[public-ip-redacted]' : address;
      return '${match[1]}$replacement$punctuation';
    });
    return wasTruncated ? '$message$_truncatedMarker' : message;
  }

  static bool _isPublicIpv4(String address) {
    final octets = address.split('.').map(int.tryParse).toList();
    if (octets.length != 4 ||
        octets.any((octet) => octet == null || octet < 0 || octet > 255)) {
      return false;
    }
    final a = octets[0]!;
    final b = octets[1]!;
    final c = octets[2]!;
    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 192 && b == 0 && (c == 0 || c == 2)) return false;
    if (a == 192 && b == 88 && c == 99) return false;
    if (a == 198 && (b == 18 || b == 19)) return false;
    if (a == 198 && b == 51 && c == 100) return false;
    if (a == 203 && b == 0 && c == 113) return false;
    return true;
  }

  static bool _isPublicIpv6(String address) {
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null || parsed.type != InternetAddressType.IPv6) return false;
    final bytes = parsed.rawAddress;
    if (bytes.every((byte) => byte == 0)) return false;
    if (bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1) {
      return false;
    }
    if (bytes[0] == 0xff) return false;
    if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return false;
    if ((bytes[0] & 0xfe) == 0xfc) return false;
    if (bytes[0] == 0x20 &&
        bytes[1] == 0x01 &&
        bytes[2] == 0x0d &&
        bytes[3] == 0xb8) {
      return false;
    }
    final isIpv4Mapped = bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (isIpv4Mapped) {
      return _isPublicIpv4(bytes.skip(12).join('.'));
    }
    return true;
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  static String sanitizeForDisplay(Object? value) {
    final safe = sanitize(value);
    return safe.replaceAllMapped(
      _httpUrlPattern,
      (match) => subscriptionUrlForDisplay(match.group(0)),
    );
  }

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
