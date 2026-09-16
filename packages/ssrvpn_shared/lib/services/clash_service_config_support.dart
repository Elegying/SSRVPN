part of 'clash_service_base.dart';

mixin _ClashConfigSupport {
  String get configDir;
  bool get isRunning;
  String? get lastStartError;

  Future<bool> startWithSmartRuleRecovery(
    Future<bool> Function() start,
    Future<void> Function() stopFailedStart,
    bool Function() isCurrent,
    String path,
  ) =>
      SmartRuleRecovery(configDir).run(
        configPath: path,
        start: start,
        stopFailedStart: stopFailedStart,
        isCurrent: isCurrent,
        isRunning: () => isRunning,
        failureReason: () => lastStartError,
        selectVersion: (version) async {
          stageSmartRuleVersionForNextConnection(version);
          await applyPendingSmartRules();
          if (_smartRuleProviderPathPrefix !=
              SmartRuleBundle.providerPathPrefix(version)) {
            throw const FormatException('恢复规则未能应用');
          }
        },
        log: (message) => log(message, event: 'rule_recovery'),
      );
  String? _smartRuleProviderPathPrefix;
  String? _pendingSmartRuleVersion;
  List<String> _androidAppRules = const [];
  List<String> get androidDirectAppPackages => _androidAppRules
      .where((rule) => rule.endsWith(',DIRECT'))
      .map((rule) => rule.split(',')[1])
      .toList(growable: false);
  bool get hasLocalSmartRules => _smartRuleProviderPathPrefix != null;

  Future<List<String>> _readAndroidAppRules(String version) async =>
      Platform.isAndroid
          ? SmartRuleBundle.androidRules(configDir, version)
          : const [];

  void stageSmartRuleVersionForNextConnection(String version) {
    _pendingSmartRuleVersion = version;
  }

  Future<void> applyPendingSmartRules() async {
    try {
      final restored =
          await SmartRuleRecovery(configDir).repairRejectedSelection();
      final version = restored ?? _pendingSmartRuleVersion;
      if (version == null) return;
      final manifest = await SmartRuleBundle.readInstalledManifest(configDir,
          expectedFileNames: {
            ...AppConstants.smartRuleProviderFiles.values,
            if (Platform.isAndroid) ...SmartRuleBundle.androidFiles
          });
      if (manifest?.version != version) throw const FormatException('待启用规则不完整');
      final appRules = await _readAndroidAppRules(version);
      // Commit the application list and provider paths together, without an await.
      _androidAppRules = appRules;
      useSmartRuleVersionForFutureConfigs(version);
      _pendingSmartRuleVersion = null;
    } catch (error) {
      log('待启用规则校验失败，继续使用当前规则',
          level: RuntimeLogLevel.warning, event: 'rule_provider_baseline');
    }
  }

  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  });

  /// Restores only missing or invalid remotely refreshable rule providers.
  /// Packaging problems stay advisory so core startup can use an existing
  /// cache or embedded conservative providers.
  @protected
  Future<void> ensureBundledSmartRules() async {
    String? restoredVersion;
    try {
      final recovery = SmartRuleRecovery(configDir);
      final restored = await recovery.repairRejectedSelection();
      if (restored != null) {
        _androidAppRules = await _readAndroidAppRules(restored);
        useSmartRuleVersionForFutureConfigs(restored);
        restoredVersion = restored;
      }
      // A past rollback must not prevent a later app upgrade from supplying a
      // fixed baseline offline. Never reinstall a version already rejected here.
      final baseline = await SmartRuleBundle.ensureInstalled(configDir,
          acceptsBundledVersion: (version) async =>
              !await recovery.rejects(version));
      final appRules = await _readAndroidAppRules(
          baseline.activeVersion ?? baseline.version);
      _androidAppRules = appRules;
      _smartRuleProviderPathPrefix = baseline.providerPathPrefix;
      log(
        baseline.activeVersion == null
            ? '智能规则本地文件已就绪，版本将在连接后校验：'
                '安装 ${baseline.installedFiles}，复用 ${baseline.reusedFiles}'
            : '智能规则基线 ${baseline.activeVersion} 已就绪：'
                '安装 ${baseline.installedFiles}，复用 ${baseline.reusedFiles}',
      );
    } catch (error) {
      if (restoredVersion == null) {
        _smartRuleProviderPathPrefix = null;
        _androidAppRules = const [];
      }
      log(
        restoredVersion != null
            ? '新版内置规则准备失败，继续使用已确认规则 $restoredVersion'
            : '智能规则基线准备失败，保留磁盘缓存并使用保守内置规则启动: '
                'cause=${_safeRuntimeLogErrorCode(error)}',
        level: RuntimeLogLevel.warning,
        event: 'rule_provider_baseline',
      );
    }
  }

  void useSmartRuleVersionForFutureConfigs(String version) {
    _smartRuleProviderPathPrefix = SmartRuleBundle.providerPathPrefix(version);
  }

  @protected
  String buildClashConfig(
    String rawYaml,
    AppSettings settings, {
    required String platformHeader,
    String? preferredNodeName,
    String? tunConfig,
    String? dnsListen,
    String? latencyTestUrl,
    bool includeFallbackGroup = false,
    Iterable<String> extraSelectGroupNames = const [],
    Iterable<String> extraRulesBeforeDirect = const [],
  }) {
    final preferredNode = preferredNodeName ?? settings.lastSelectedNodeName;
    final extraGroups = List<String>.unmodifiable(extraSelectGroupNames);
    final extraRules = List<String>.unmodifiable(extraRulesBeforeDirect);
    return ClashConfigGenerator.generateConfig(
      rawYaml,
      settings,
      preferredNodeName: preferredNode,
      platformHeader: platformHeader,
      tunConfig: tunConfig,
      dnsListen: dnsListen,
      latencyTestUrl: latencyTestUrl,
      includeFallbackGroup: includeFallbackGroup,
      extraSelectGroupNames: extraGroups,
      extraRulesBeforeDirect: [..._androidAppRules, ...extraRules],
      smartRuleProviderPathPrefix: _smartRuleProviderPathPrefix,
    );
  }

  @protected
  Future<String> buildClashConfigAsync(
    String rawYaml,
    AppSettings settings, {
    required String platformHeader,
    String? preferredNodeName,
    String? tunConfig,
    String? dnsListen,
    String? latencyTestUrl,
    bool includeFallbackGroup = false,
    Iterable<String> extraSelectGroupNames = const [],
    Iterable<String> extraRulesBeforeDirect = const [],
  }) {
    final preferredNode = preferredNodeName ?? settings.lastSelectedNodeName;
    return ClashConfigGenerator.generateConfigAsync(
      rawYaml,
      settings,
      preferredNodeName: preferredNode,
      platformHeader: platformHeader,
      tunConfig: tunConfig,
      dnsListen: dnsListen,
      latencyTestUrl: latencyTestUrl,
      includeFallbackGroup: includeFallbackGroup,
      extraSelectGroupNames: extraSelectGroupNames,
      extraRulesBeforeDirect: [..._androidAppRules, ...extraRulesBeforeDirect],
      smartRuleProviderPathPrefix: _smartRuleProviderPathPrefix,
    );
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
