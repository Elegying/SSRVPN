class RuntimeConfigNamePolicy {
  const RuntimeConfigNamePolicy._();

  static final RegExp _unsafeScalarControls = RegExp(r'[\x00-\x1f\x7f]');

  /// Uses the same scalar normalization everywhere a subscription-provided
  /// name enters Mihomo's shared proxy/group namespace. Collision checks must
  /// run after this step because Mihomo receives the sanitized value.
  static String canonicalName(Object? value) =>
      sanitizeScalar(value?.toString() ?? '').trim();

  static String sanitizeScalar(String value) =>
      value.replaceAll(_unsafeScalarControls, '');

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
