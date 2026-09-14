part of 'clash_service_base.dart';

mixin _ClashRuleProviderSupport {
  bool _ruleProviderRefreshScheduled = false;
  bool _ruleProviderRefreshInProgress = false;
  int get _healthMonitorEpoch;
  String? _ruleDownloadVersion;
  @protected
  String get ruleSigningPublicKey => SmartRuleSignature.publicKey;
  bool get isRunning;
  String get configDir;
  AppSettings get settings;
  void stageSmartRuleVersionForNextConnection(String version);
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  });

  @protected
  Future<void> refreshRuleProvidersOnce() async {
    if (!isRunning || configDir.isEmpty || _ruleProviderRefreshInProgress) {
      return;
    }
    final session = _healthMonitorEpoch;
    bool isCurrent() => isRunning && session == _healthMonitorEpoch;
    _ruleProviderRefreshInProgress = true;

    final expectedFileNames = {
      ...AppConstants.smartRuleProviderFiles.values,
      if (Platform.isAndroid) ...SmartRuleBundle.androidFiles,
    };
    try {
      final versionText = await fetchSmartRuleChannelFile(
        AppConstants.smartRuleVersionDescriptorFile,
        maxBytes: SmartRuleBundle.maxVersionDescriptorBytes,
      );
      if (!isCurrent()) return;
      if (!await SmartRuleSignature.verify(versionText,
          trustedPublicKey: ruleSigningPublicKey)) {
        throw const FormatException('规则发布签名无效');
      }
      if (!isCurrent()) return;
      final remote = SmartRuleBundle.parseVersionDescriptor(versionText);
      final recovery = SmartRuleRecovery(configDir);
      if (await recovery.rejects(remote.version)) {
        log('跳过本机已拒绝的规则快照 ${remote.version}', event: 'rule_provider_refresh');
        return;
      }
      _ruleDownloadVersion = remote.version;
      final installedManifest = await SmartRuleBundle.readInstalledManifest(
        configDir,
        expectedFileNames: expectedFileNames,
      );
      if (!isCurrent()) return;
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

      if (!await recovery.hasConfirmedVersion) {
        log('尚未持久化可用规则版本，本次保留现有规则', event: 'rule_provider_refresh');
        return;
      }
      if (!isCurrent()) return;
      final manifestText = await fetchSmartRuleChannelFile(
        AppConstants.smartRuleManifestFile,
        maxBytes: SmartRuleBundle.maxManifestBytes,
      );
      if (!isCurrent()) return;
      if (!remote.acceptsManifest(manifestText)) {
        throw const FormatException('智能规则清单摘要与版本文件不匹配');
      }
      final manifest = SmartRuleBundle.parseManifest(
        manifestText,
        expectedFileNames: expectedFileNames,
      );
      if (manifest.componentVersions.length != 3) {
        throw const FormatException('规则组件版本缺失');
      }
      for (final entry in manifest.componentVersions.entries) {
        final old = installedManifest?.componentVersions[entry.key];
        if (old != null &&
            entry.value != old &&
            !SmartRuleVersionDescriptor(
                    version: entry.value, manifestSha256: '')
                .isNewerThan(old)) {
          throw const FormatException('拒绝规则组件降级');
        }
      }
      if (manifest.version != remote.version) {
        throw const FormatException('智能规则清单与线上版本号不匹配');
      }

      final changedProviders = manifest.files.entries
          .where((entry) => !entry.value.hasSameContentAs(
                installedManifest?.files[entry.key],
              ))
          .toList(growable: false);
      for (final entry in changedProviders) {
        final component = entry.key == 'direct_apps.yaml'
            ? 'directApps'
            : entry.key == 'proxy_apps.yaml'
                ? 'proxyApps'
                : 'rules';
        final old = installedManifest?.componentVersions[component];
        if (old != null &&
            !SmartRuleVersionDescriptor(
                    version: manifest.componentVersions[component]!,
                    manifestSha256: '')
                .isNewerThan(old)) {
          throw const FormatException('内容变化但组件版本未提升');
        }
      }
      final providerContents = <String, String>{};
      for (final entry in changedProviders) {
        if (!isCurrent()) return;
        providerContents[entry.key] = await fetchSmartRuleChannelFile(
          entry.key,
          maxBytes: SmartRuleBundle.maxProviderBytes,
        );
      }
      if (!isCurrent()) return;
      final installed = await SmartRuleBundle.installVerifiedProviderFiles(
        configDir,
        manifest,
        providerContents,
      );
      if (!installed) {
        log(
          '智能规则校验或落盘失败，继续使用现有本地规则，下次启动再检查',
          level: RuntimeLogLevel.warning,
          event: 'rule_provider_refresh',
        );
        return;
      }
      if (!isCurrent()) return;
      final activated = await SmartRuleBundle.activateInstalledManifest(
        configDir,
        manifestText,
        expectedFileNames: expectedFileNames,
      );
      if (!activated) {
        log(
          '智能规则文件校验未通过，保留旧版本记录并在下次启动检查',
          level: RuntimeLogLevel.warning,
          event: 'rule_provider_refresh',
        );
        return;
      }
      if (!isCurrent()) return;
      stageSmartRuleVersionForNextConnection(remote.version);
      log(
        '智能规则 ${remote.version} 已完整下载并校验'
        '（更新 ${changedProviders.length} 个文件），下次连接整体启用；'
        '当前连接继续使用 ${installedVersion ?? '现有'} 版本',
        event: 'rule_provider_refresh',
      );
    } catch (error) {
      log(
        '智能规则后台检查失败，继续使用现有本地规则: '
        'cause=${_safeRuntimeLogErrorCode(error)}',
        level: RuntimeLogLevel.warning,
        event: 'rule_provider_refresh',
      );
    } finally {
      _ruleDownloadVersion = null;
      _ruleProviderRefreshInProgress = false;
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
      if (Platform.isAndroid) ...SmartRuleBundle.androidFiles,
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
        fileName == AppConstants.smartRuleVersionDescriptorFile
            ? Uri.parse('${AppConstants.smartRuleChannelBaseUrl}/$fileName')
            : Uri.parse('${AppConstants.smartRuleChannelBaseUrl}/')
                .resolve('../snapshots/$_ruleDownloadVersion/$fileName'),
      )
        ..headers[HttpHeaders.acceptHeader] =
            allowedMetadataFiles.contains(fileName)
                ? 'application/json'
                : 'application/yaml, text/yaml, text/plain'
        ..headers[HttpHeaders.cacheControlHeader] = 'no-cache'
        ..headers[HttpHeaders.userAgentHeader] = AppConstants.appUserAgent;
      request.followRedirects = false;
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
