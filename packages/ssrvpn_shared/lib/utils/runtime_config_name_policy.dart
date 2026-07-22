class RuntimeConfigNamePolicy {
  const RuntimeConfigNamePolicy._();

  /// Names emitted by the shared generator on one or more platforms.
  /// Subscription nodes must never use these names because Mihomo resolves
  /// proxies and proxy groups in the same runtime namespace.
  static const Set<String> reservedProxyNames = {
    'PROXY',
    'GLOBAL',
    '自动选择',
    '故障转移',
    'SSRVPN-GEO',
  };

  static const Set<String> standardGroupNames = {
    'PROXY',
    'GLOBAL',
    '自动选择',
    '故障转移',
  };

  static List<String> normalizeExtraGroupNames(Iterable<String> names) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final value in names) {
      final name = value.trim();
      if (name.isEmpty) continue;
      if (standardGroupNames.contains(name)) {
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
