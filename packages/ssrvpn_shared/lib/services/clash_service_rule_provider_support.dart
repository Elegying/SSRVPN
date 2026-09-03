part of 'clash_service_base.dart';

mixin _ClashRuleProviderSupport {
  bool get isRunning;
  String get configDir;
  AppSettings get settings;
  http.Client? get apiClient;
  String _apiUrl(String path);
  Map<String, String> apiHeaders({bool json = false});
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  });

  @protected
  Future<void> refreshRuleProvidersOnce() async {
    if (!isRunning || configDir.isEmpty) return;
    final client = apiClient;
    if (client == null) return;

    final expectedFileNames =
        AppConstants.smartRuleProviderFiles.values.toSet();
    try {
      final versionText = await fetchSmartRuleChannelFile(
        AppConstants.smartRuleVersionDescriptorFile,
        maxBytes: SmartRuleBundle.maxVersionDescriptorBytes,
      );
      final remote = SmartRuleBundle.parseVersionDescriptor(versionText);
      final installedManifest = await SmartRuleBundle.readInstalledManifest(
        configDir,
        expectedFileNames: expectedFileNames,
      );
      final installedVersion = installedManifest?.version;
      if (!remote.isNewerThan(installedVersion)) {
        log(
          installedVersion == remote.version
              ? '智能规则已是最新版本 $installedVersion，无需下载'
              : '本地智能规则 $installedVersion 不低于线上 ${remote.version}，保留本地版本',
          event: 'rule_provider_refresh',
        );
        return;
      }

      final manifestText = await fetchSmartRuleChannelFile(
        AppConstants.smartRuleManifestFile,
        maxBytes: SmartRuleBundle.maxManifestBytes,
      );
      if (!remote.acceptsManifest(manifestText)) {
        throw const FormatException('智能规则清单摘要与版本文件不匹配');
      }
      final manifest = SmartRuleBundle.parseManifest(
        manifestText,
        expectedFileNames: expectedFileNames,
      );
      if (manifest.version != remote.version) {
        throw const FormatException('智能规则清单与线上版本号不匹配');
      }

      final changedProviders = AppConstants.smartRuleProviderFiles.entries
          .where((entry) => !manifest.files[entry.value]!.hasSameContentAs(
                installedManifest?.files[entry.value],
              ))
          .toList(growable: false);
      final providerContents = <String, String>{};
      for (final entry in changedProviders) {
        if (!isRunning) return;
        providerContents[entry.value] = await fetchSmartRuleChannelFile(
          entry.value,
          maxBytes: SmartRuleBundle.maxProviderBytes,
        );
      }
      if (!SmartRuleBundle.providerContentsMatch(manifest, providerContents)) {
        throw const FormatException('智能规则文件与清单不匹配');
      }

      var refreshedProviders = 0;
      for (final entry in changedProviders) {
        if (!isRunning) return;
        final response = await client
            .put(
              Uri.parse(
                _apiUrl(
                  '/providers/rules/${Uri.encodeComponent(entry.key)}',
                ),
              ),
              headers: apiHeaders(),
            )
            .timeout(AppConstants.apiTimeout);
        if (response.statusCode != 200 && response.statusCode != 204) {
          log(
            '智能规则更新未完成 ${entry.key}: HTTP ${response.statusCode}，保留旧版本记录',
            level: RuntimeLogLevel.warning,
            event: 'rule_provider_refresh',
          );
          return;
        }
        refreshedProviders++;
      }
      if (!isRunning) return;
      final installed = await SmartRuleBundle.installVerifiedProviderFiles(
        configDir,
        manifest,
        providerContents,
      );
      if (!installed) {
        log(
          '智能规则本地文件未能安全落盘，保留旧版本记录并在下次连接重试',
          level: RuntimeLogLevel.warning,
          event: 'rule_provider_refresh',
        );
        return;
      }
      final activated = await SmartRuleBundle.activateInstalledManifest(
        configDir,
        manifestText,
        expectedFileNames: expectedFileNames,
      );
      if (!activated) {
        log(
          '智能规则文件校验未通过，保留旧版本记录并在下次连接重试',
          level: RuntimeLogLevel.warning,
          event: 'rule_provider_refresh',
        );
        return;
      }
      log(
        '智能规则已从 ${installedVersion ?? '未知版本'} 更新至 ${remote.version}'
        '（刷新 $refreshedProviders 个变更文件）',
        event: 'rule_provider_refresh',
      );
    } catch (error) {
      log(
        '智能规则后台检查失败，继续使用现有本地规则: '
        'cause=${_safeRuntimeLogErrorCode(error)}',
        level: RuntimeLogLevel.warning,
        event: 'rule_provider_refresh',
      );
    }
  }

  /// Fetches allowlisted rule-channel files through the currently selected
  /// proxy. Provider payloads are requested only after the small version and
  /// manifest gates prove that a newer, bound bundle exists.
  @protected
  Future<String> fetchSmartRuleChannelFile(
    String fileName, {
    required int maxBytes,
  }) async {
    const allowedMetadataFiles = {
      AppConstants.smartRuleVersionDescriptorFile,
      AppConstants.smartRuleManifestFile,
    };
    final allowedFiles = {
      ...allowedMetadataFiles,
      ...AppConstants.smartRuleProviderFiles.values,
    };
    if (!allowedFiles.contains(fileName) || maxBytes <= 0) {
      throw ArgumentError.value(fileName, 'fileName', '规则元数据文件无效');
    }
    final rawClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'PROXY 127.0.0.1:${settings.proxyPort}';
    final proxyClient = IOClient(rawClient);
    try {
      final request = http.Request(
        'GET',
        Uri.parse('${AppConstants.smartRuleChannelBaseUrl}/$fileName'),
      )
        ..headers[HttpHeaders.acceptHeader] =
            allowedMetadataFiles.contains(fileName)
                ? 'application/json'
                : 'application/yaml, text/yaml, text/plain'
        ..headers[HttpHeaders.cacheControlHeader] = 'no-cache'
        ..headers[HttpHeaders.userAgentHeader] = AppConstants.appUserAgent;
      final response =
          await proxyClient.send(request).timeout(const Duration(seconds: 8));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('规则通道返回 HTTP ${response.statusCode}');
      }
      final declaredLength = response.contentLength;
      if (declaredLength != null && declaredLength > maxBytes) {
        throw const FormatException('规则通道文件超过大小限制');
      }
      final bytes = BytesBuilder(copy: false);
      await (() async {
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const FormatException('规则通道文件超过大小限制');
          }
          bytes.add(chunk);
        }
      })()
          .timeout(const Duration(seconds: 12));
      return utf8.decode(bytes.takeBytes());
    } finally {
      proxyClient.close();
    }
  }
}
