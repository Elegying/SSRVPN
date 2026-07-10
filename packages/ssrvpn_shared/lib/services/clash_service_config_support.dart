part of 'clash_service_base.dart';

mixin _ClashConfigSupport {
  _ClashConfigCacheKey? _lastGeneratedConfigKey;
  String? _lastGeneratedConfig;

  @protected
  String buildClashConfig(
    String rawYaml,
    AppSettings settings, {
    required String platformHeader,
    String? preferredNodeName,
    String? tunConfig,
    String? latencyTestUrl,
    bool includeFallbackGroup = false,
    bool includeGeoIpRules = false,
    Iterable<String> extraSelectGroupNames = const [],
    Iterable<String> extraRulesBeforeDirect = const [],
  }) {
    final preferredNode = preferredNodeName ?? settings.lastSelectedNodeName;
    final extraGroups = List<String>.unmodifiable(extraSelectGroupNames);
    final extraRules = List<String>.unmodifiable(extraRulesBeforeDirect);
    final cacheKey = _ClashConfigCacheKey(
      rawYaml: rawYaml,
      settings: settings,
      preferredNodeName: preferredNode,
      platformHeader: platformHeader,
      tunConfig: tunConfig,
      latencyTestUrl: latencyTestUrl,
      includeFallbackGroup: includeFallbackGroup,
      includeGeoIpRules: includeGeoIpRules,
      extraSelectGroupNames: extraGroups,
      extraRulesBeforeDirect: extraRules,
    );
    if (_lastGeneratedConfigKey == cacheKey && _lastGeneratedConfig != null) {
      return _lastGeneratedConfig!;
    }

    final output = ClashConfigGenerator.generateConfig(
      rawYaml,
      settings,
      preferredNodeName: preferredNode,
      platformHeader: platformHeader,
      tunConfig: tunConfig,
      latencyTestUrl: latencyTestUrl,
      includeFallbackGroup: includeFallbackGroup,
      includeGeoIpRules: includeGeoIpRules,
      extraSelectGroupNames: extraGroups,
      extraRulesBeforeDirect: extraRules,
    );
    _lastGeneratedConfigKey = cacheKey;
    _lastGeneratedConfig = output;
    return output;
  }

  /// Extracts one top-level YAML section while preserving relative indentation.
  String extractSection(String yaml, String sectionName) {
    if (sectionName == 'proxies') {
      return ClashConfigGenerator.buildProxiesText(yaml);
    }

    final normalized = yaml.replaceAll('\t', '    ');
    final lines = normalized.split('\n');
    final sectionLines = <String>[];
    var inSection = false;

    for (final line in lines) {
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        if (line.trim().startsWith('$sectionName:')) {
          inSection = true;
          continue;
        } else if (inSection &&
            line.trim().contains(':') &&
            !line.trim().startsWith('#') &&
            !line.trim().startsWith('-')) {
          break;
        }
      }
      if (inSection) sectionLines.add(line);
    }

    var minIndent = 999;
    for (final line in sectionLines) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      final indent = line.length - trimmed.length;
      if (indent < minIndent) minIndent = indent;
    }
    if (minIndent == 999) minIndent = 0;

    final buffer = StringBuffer();
    for (final line in sectionLines) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      final delta = line.length - trimmed.length - minIndent;
      buffer.writeln('${' ' * (delta + 2)}$trimmed');
    }
    return buffer.toString().trimRight();
  }

  List<String> extractProxyNames(String rawYaml) {
    return ClashConfigGenerator.extractProxyNames(rawYaml);
  }

  List<String> extractProxyNamesFromText(String rawYaml) {
    final names = <String>[];
    try {
      final proxiesSection = extractSection(rawYaml, 'proxies');
      for (final line in proxiesSection.split('\n')) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('-')) continue;
        final nameMatch = RegExp(
          r'''name:\s*['"]?([^'"\n,]+)['"]?''',
        ).firstMatch(trimmed);
        if (nameMatch != null) names.add(nameMatch.group(1)!.trim());
      }
    } catch (_) {}
    return names;
  }

  String yamlQuote(String name) {
    final sanitized = name
        .replaceAll('\\', '\\\\')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    return "'${sanitized.replaceAll("'", "''")}'";
  }
}

class _ClashConfigCacheKey {
  final String rawYaml;
  final AppSettings settings;
  final String? preferredNodeName;
  final String platformHeader;
  final String? tunConfig;
  final String? latencyTestUrl;
  final bool includeFallbackGroup;
  final bool includeGeoIpRules;
  final List<String> extraSelectGroupNames;
  final List<String> extraRulesBeforeDirect;

  const _ClashConfigCacheKey({
    required this.rawYaml,
    required this.settings,
    required this.preferredNodeName,
    required this.platformHeader,
    required this.tunConfig,
    required this.latencyTestUrl,
    required this.includeFallbackGroup,
    required this.includeGeoIpRules,
    required this.extraSelectGroupNames,
    required this.extraRulesBeforeDirect,
  });

  @override
  bool operator ==(Object other) {
    return other is _ClashConfigCacheKey &&
        other.rawYaml == rawYaml &&
        other.settings == settings &&
        other.preferredNodeName == preferredNodeName &&
        other.platformHeader == platformHeader &&
        other.tunConfig == tunConfig &&
        other.latencyTestUrl == latencyTestUrl &&
        other.includeFallbackGroup == includeFallbackGroup &&
        other.includeGeoIpRules == includeGeoIpRules &&
        _stringListEquals(other.extraSelectGroupNames, extraSelectGroupNames) &&
        _stringListEquals(other.extraRulesBeforeDirect, extraRulesBeforeDirect);
  }

  @override
  int get hashCode => Object.hash(
        rawYaml,
        settings,
        preferredNodeName,
        platformHeader,
        tunConfig,
        latencyTestUrl,
        includeFallbackGroup,
        includeGeoIpRules,
        Object.hashAll(extraSelectGroupNames),
        Object.hashAll(extraRulesBeforeDirect),
      );
}

bool _stringListEquals(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
