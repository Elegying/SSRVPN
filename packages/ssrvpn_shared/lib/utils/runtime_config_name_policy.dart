import 'dart:convert';

import 'package:crypto/crypto.dart';

class RuntimeConfigNamePolicy {
  const RuntimeConfigNamePolicy._();

  static final RegExp _nameControls = RegExp(r'[\x00-\x1f\x7f]');
  static final RegExp _invalidDataScalarControls =
      RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]');
  static final RegExp _httpHeaderVisibleAscii = RegExp(r'^[\x21-\x7e]+$');
  static const _maxInlineApiSecretBytes = 256;
  static const _apiSecretHashDomain = 'SSRVPN/API-secret/v1\u0000';
  static const _apiSecretHashPrefix = 'ssrvpn-sha256-';

  /// Uses the same scalar normalization everywhere a subscription-provided
  /// name enters Mihomo's shared proxy/group namespace. Collision checks must
  /// run after this step because Mihomo receives the sanitized value.
  static String canonicalName(Object? value) =>
      (value?.toString() ?? '').replaceAll(_nameControls, '').trim();

  /// Removes characters that cannot safely appear in YAML data while keeping
  /// tab, newline, and carriage return for JSON/YAML encoders to escape.
  static String sanitizeDataScalar(String value) =>
      value.replaceAll(_invalidDataScalarControls, '');

  /// Returns one value that is safe and identical for both Mihomo's `secret`
  /// field and the HTTP `Authorization: Bearer ...` header.
  ///
  /// Visible ASCII secrets up to the bounded HTTP-header size remain
  /// byte-for-byte stable. Other non-empty values are domain-separated and
  /// hashed instead of having controls removed, which prevents an unsafe
  /// secret from becoming empty or colliding with a different original value
  /// after lossy normalization.
  static String canonicalApiSecret(String value) {
    if (value.isEmpty) return value;
    if (value.length <= _maxInlineApiSecretBytes &&
        _httpHeaderVisibleAscii.hasMatch(value)) {
      return value;
    }
    final digest = sha256.convert(
      utf8.encode('$_apiSecretHashDomain$value'),
    );
    return '$_apiSecretHashPrefix$digest';
  }

  /// Names emitted by the shared generator on one or more platforms.
  /// Subscription nodes must never use these names because Mihomo resolves
  /// proxies and proxy groups in the same runtime namespace.
  static const Set<String> mihomoBuiltinPolicyNames = {
    // Mihomo built-in policy names share the same lookup surface as proxy
    // names. Keeping them available for rules and group membership avoids a
    // user node silently resolving to DIRECT/REJECT instead of that node.
    'DIRECT',
    'REJECT',
    'REJECT-DROP',
    'PASS',
    'COMPATIBLE',
  };

  static const Set<String> standardGroupNames = {
    'PROXY',
    'GLOBAL',
    '自动选择',
    '故障转移',
  };

  static const Set<String> reservedProxyNames = {
    ...mihomoBuiltinPolicyNames,
    ...standardGroupNames,
    'SSRVPN-GEO',
  };

  static List<String> normalizeExtraGroupNames(Iterable<String> names) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final value in names) {
      final name = canonicalName(value);
      if (name.isEmpty) continue;
      if (standardGroupNames.contains(name) ||
          mihomoBuiltinPolicyNames.contains(name)) {
        throw ArgumentError.value(
          value,
          'extraSelectGroupNames',
          'must not collide with an SSRVPN built-in proxy group',
        );
      }
      if (seen.add(name)) normalized.add(name);
    }
    return List<String>.unmodifiable(normalized);
  }
}
