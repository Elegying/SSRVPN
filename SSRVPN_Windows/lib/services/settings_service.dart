import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show
        AsyncLazy,
        RecoveringSerialQueue,
        NodePreferenceStore,
        NodePreferenceRename,
        NodePreferenceWrite,
        RuntimeConfigNamePolicy,
        SubscriptionUndoRecord;
import '../models/app_settings.dart';
import 'windows_dpapi_secret_store.dart';

/// 设置持久化服务（Windows 安装版）。
///
/// 数据优先放在内部应用 EXE 旁；目录不可写时回退到 LocalAppData。
class SettingsService extends ChangeNotifier implements NodePreferenceStore {
  static const _apiSecretFileName = '.api-secret.dpapi';
  // Keep the legacy filename so completed migrations are not replayed after
  // the portable distribution channel is retired.
  static const _installedMigrationMarkerName = '.portable-migration-v1';
  static const _installedDataFiles = [
    _apiSecretFileName,
    'settings.json',
    'subscriptions.json',
    'subscription_cache.yaml',
    'config.yaml',
    'country.mmdb',
    'geoip.metadb',
  ];
  static const _criticalInstalledDataFiles = {
    _apiSecretFileName,
    'settings.json',
    'subscriptions.json',
  };
  static final _instance = AsyncLazy<SettingsService>();
  late AppSettings _settings;
  late String _settingsPath;
  late String _dataDir;
  String? _storageNotice;
  final Future<String?> Function()? _readApiSecretOverride;
  final Future<void> Function(String value)? _writeApiSecretOverride;
  final Future<void> Function(AppSettings settings)? _writeSettingsOverride;

  SettingsService._({
    Future<String?> Function()? readApiSecret,
    Future<void> Function(String value)? writeApiSecret,
    Future<void> Function(AppSettings settings)? writeSettings,
  })  : _readApiSecretOverride = readApiSecret,
        _writeApiSecretOverride = writeApiSecret,
        _writeSettingsOverride = writeSettings;

  @visibleForTesting
  static Future<SettingsService> createForTesting({
    AppSettings? settings,
    required String dataDir,
    required String settingsPath,
    Future<String?> Function()? readApiSecret,
    Future<void> Function(String value)? writeApiSecret,
    Future<void> Function(AppSettings settings)? writeSettings,
  }) async {
    final service = SettingsService._(
      readApiSecret: readApiSecret,
      writeApiSecret: writeApiSecret,
      writeSettings: writeSettings,
    )
      .._dataDir = dataDir
      .._settingsPath = settingsPath;
    if (settings == null) {
      await service._load();
    } else {
      service._settings = settings;
    }
    return service;
  }

  static Future<SettingsService> getInstance() => _instance.get(() async {
        final service = SettingsService._();
        await service._init();
        return service;
      });

  static void resetInstanceForRecovery() => _instance.reset();

  Future<void> _init() async {
    _dataDir = await _resolveDataDirectory();
    _settingsPath = '$_dataDir${Platform.pathSeparator}settings.json';

    await _load();
  }

  AppSettings get settings => _settings;
  String get dataDir => _dataDir;
  String? get storageNotice => _storageNotice;

  Future<String?> _readSecureApiSecret() {
    final override = _readApiSecretOverride;
    return override != null
        ? override()
        : WindowsDpapiSecretStore(_dataDir).read();
  }

  Future<void> _writeSecureApiSecret(String value) {
    final override = _writeApiSecretOverride;
    return override != null
        ? override(value)
        : WindowsDpapiSecretStore(_dataDir).write(value);
  }

  Future<String> _resolveDataDirectory() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final installedDir = '$exeDir${Platform.pathSeparator}ssrvpn';
    try {
      await _verifyWritableDirectory(installedDir);
      return installedDir;
    } catch (e) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData == null || localAppData.trim().isEmpty) {
        rethrow;
      }

      final fallbackDir =
          '$localAppData${Platform.pathSeparator}SSRVPN${Platform.pathSeparator}ssrvpn';
      await _verifyWritableDirectory(fallbackDir);
      await _migrateInstalledData(installedDir, fallbackDir);
      _storageNotice = '程序目录不可写，数据已改存到 $fallbackDir（原因: $e）';
      return fallbackDir;
    }
  }

  Future<void> _verifyWritableDirectory(String path) async {
    final directory = Directory(path);
    await directory.create(recursive: true);
    final probe = File(
      '$path${Platform.pathSeparator}.write_test_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await probe.writeAsString('ok', flush: true);
    } finally {
      if (await probe.exists()) await probe.delete();
    }
  }

  @visibleForTesting
  static Future<void> migrateInstalledDataForTesting(
    String installedDir,
    String fallbackDir,
  ) =>
      _migrateInstalledData(installedDir, fallbackDir);

  static Future<void> _migrateInstalledData(
    String installedDir,
    String fallbackDir,
  ) async {
    final source = Directory(installedDir);
    if (!await source.exists()) return;
    final migrationMarker = File(
      '$fallbackDir${Platform.pathSeparator}$_installedMigrationMarkerName',
    );
    final markerType = await FileSystemEntity.type(
      migrationMarker.path,
      followLinks: false,
    );
    if (markerType == FileSystemEntityType.file &&
        (await migrationMarker.readAsString()).trim() == '1') {
      return;
    }
    if (markerType != FileSystemEntityType.notFound &&
        markerType != FileSystemEntityType.file) {
      throw FileSystemException(
        'Installed migration marker must be a regular file',
        migrationMarker.path,
      );
    }

    // The installed directory may be read-only. Migrate the committed snapshot
    // from its undo record without changing the source or copying staged data.
    final undo = await SubscriptionUndoRecord.read(File(
      '$installedDir${Platform.pathSeparator}${SubscriptionUndoRecord.fileName}',
    ));
    final recovered = <String, String?>{...?undo?.files};
    final preference = undo?.preference;
    if (preference != null) {
      final settings = await NodePreferenceWrite.readSettings(
        File('$installedDir${Platform.pathSeparator}settings.json'),
      );
      if (settings != null && preference.recoverJson(settings)) {
        recovered['settings.json'] = jsonEncode(settings);
      }
    }
    final targetJournal =
        '$fallbackDir${Platform.pathSeparator}${SubscriptionUndoRecord.fileName}';
    if (await FileSystemEntity.type(targetJournal, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('Fallback data has a pending subscription recovery');
    }

    for (final name in _installedDataFiles) {
      final sourceFile = File('$installedDir${Platform.pathSeparator}$name');
      final targetFile = File('$fallbackDir${Platform.pathSeparator}$name');
      final fromUndo = recovered.containsKey(name);
      final restoredBytes =
          recovered[name] == null ? null : utf8.encode(recovered[name]!);
      final critical = _criticalInstalledDataFiles.contains(name) || fromUndo;
      final sourceType = await FileSystemEntity.type(
        sourceFile.path,
        followLinks: false,
      );
      if (!fromUndo && sourceType == FileSystemEntityType.notFound) continue;
      if (!fromUndo && sourceType != FileSystemEntityType.file) {
        if (critical) {
          throw FileSystemException(
            'Critical installed data must be a regular file',
            sourceFile.path,
          );
        }
        continue;
      }

      final targetType = await FileSystemEntity.type(
        targetFile.path,
        followLinks: false,
      );
      if (fromUndo && restoredBytes == null) {
        if (targetType != FileSystemEntityType.notFound) {
          throw StateError('Installed recovery conflicts with fallback $name');
        }
        continue;
      }
      if (targetType != FileSystemEntityType.notFound) {
        if (critical) {
          if (targetType != FileSystemEntityType.file) {
            throw FileSystemException(
              'Critical fallback data must be a regular file',
              targetFile.path,
            );
          }
          if (!listEquals(
            restoredBytes ?? await sourceFile.readAsBytes(),
            await targetFile.readAsBytes(),
          )) {
            throw StateError(
              'Installed data conflicts with existing fallback $name',
            );
          }
        }
        continue;
      }

      try {
        await _copyInstalledFile(sourceFile, targetFile,
            bytes: restoredBytes ??
                (critical ? await sourceFile.readAsBytes() : null));
      } catch (error, stackTrace) {
        if (critical) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        // A single locked cache file should not block application startup.
      }
    }

    final temporaryMarker = File('${migrationMarker.path}.tmp');
    try {
      await temporaryMarker.writeAsString('1\n', flush: true);
      await temporaryMarker.rename(migrationMarker.path);
    } catch (error, stackTrace) {
      try {
        if (await temporaryMarker.exists()) await temporaryMarker.delete();
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  static Future<void> _copyInstalledFile(File source, File target,
      {List<int>? bytes}) async {
    // An interrupted copy must not leave a partial final file that a retry
    // would mistake for conflicting user data.
    final temporary = File(
        '${target.path}.migration.$pid.${DateTime.now().microsecondsSinceEpoch}');
    try {
      await temporary.create(exclusive: true);
      if (bytes == null) {
        await source.copy(temporary.path);
      } else {
        await temporary.writeAsBytes(bytes, flush: true);
        if (!listEquals(bytes, await temporary.readAsBytes())) {
          throw StateError('Installed data migration verification failed');
        }
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _load() async {
    final file = File(_settingsPath);
    Map<String, dynamic>? decodedSettings;
    String? badSettingsReason;
    String? recoverableLegacySecret;
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('settings.json must be a JSON object');
        }
        decodedSettings = decoded;
        final rawSecret = decoded['apiSecret'];
        if (rawSecret is String && rawSecret.isNotEmpty) {
          recoverableLegacySecret = rawSecret;
        }
        _settings = AppSettings.fromJson(decoded);
      } catch (e) {
        badSettingsReason =
            'settings.json could not be parsed (${e.runtimeType})';
        _settings = AppSettings(apiSecret: recoverableLegacySecret ?? '');
      }
    } else {
      _settings = AppSettings();
    }

    final legacySecret = _settings.apiSecret;
    final secureSecret = await _readSecureApiSecret();
    if (secureSecret != null && secureSecret.isNotEmpty) {
      _settings = _settings.copyWith(apiSecret: secureSecret);
    } else if (legacySecret.isNotEmpty) {
      await _writeVerifiedApiSecret(legacySecret);
    } else {
      final generatedSecret = _generateSecret();
      await _writeVerifiedApiSecret(generatedSecret);
      _settings = _settings.copyWith(apiSecret: generatedSecret);
    }

    if (badSettingsReason != null) {
      await _backupBadFile(file, badSettingsReason, decoded: decodedSettings);
    }

    if (legacySecret.isNotEmpty ||
        badSettingsReason != null ||
        !await file.exists()) {
      await _persistSettings(_settings);
    }
  }

  Future<void> _writeVerifiedApiSecret(String value) async {
    await _writeSecureApiSecret(value);
    if (await _readSecureApiSecret() != value) {
      throw StateError('Windows secure storage did not retain the API secret');
    }
  }

  Future<void> _replaceVerifiedApiSecret(
    String value,
    AppSettings candidate,
  ) async {
    final previousSecret = _settings.apiSecret;
    try {
      await _writeSecureApiSecret(value);
      if (await _readSecureApiSecret() != value) {
        throw StateError(
          'Windows secure storage did not retain the API secret',
        );
      }
      _settings = candidate;
    } catch (error, stackTrace) {
      try {
        await _writeSecureApiSecret(previousSecret);
        if (await _readSecureApiSecret() != previousSecret) {
          throw StateError(
            'Windows secure storage rollback verification failed',
          );
        }
      } catch (rollbackError) {
        throw StateError(
          'API secret replacement failed ($error) and rollback failed '
          '($rollbackError)',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _backupBadFile(
    File file,
    String reason, {
    Map<String, dynamic>? decoded,
  }) async {
    if (!await file.exists()) return;
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '');
    final backup = File('${file.path}.bad-$stamp');
    final sanitized = decoded == null
        ? <String, dynamic>{'originalContentOmitted': true, 'reason': reason}
        : (Map<String, dynamic>.from(decoded)..remove('apiSecret'));
    await backup.writeAsString(jsonEncode(sanitized), flush: true);
    await File('${backup.path}.reason.txt').writeAsString(reason, flush: true);
    await file.delete();
  }

  String _generateSecret() {
    final rand = Random.secure();
    return List.generate(
      16,
      (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  final RecoveringSerialQueue _saveQueue = RecoveringSerialQueue();

  Future<void> _writeSettingsFile(AppSettings settings) async {
    final persisted = settings.toJson()..remove('apiSecret');
    final settingsJson = jsonEncode(persisted);
    final file = File(_settingsPath);
    await file.parent.create(recursive: true);
    final temp = File(
      '$_settingsPath.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(settingsJson, flush: true);
    await temp.rename(file.path);
  }

  Future<void> _persistSettings(AppSettings settings) {
    final override = _writeSettingsOverride;
    return override != null ? override(settings) : _writeSettingsFile(settings);
  }

  Future<void> save() {
    return _saveQueue.add(() async {
      final snapshot = AppSettings.fromJson(_settings.toJson());
      await _persistSettings(snapshot);
      notifyListeners();
    });
  }

  Future<void> _updateSettings(void Function(AppSettings) update) {
    return _saveQueue.add(() async {
      final candidate = AppSettings.fromJson(_settings.toJson());
      update(candidate);
      if (candidate == _settings) return;
      await _persistSettings(candidate);
      _settings = candidate;
      notifyListeners();
    });
  }

  Future<void> flush() => _saveQueue.flush();

  Future<void> resetAppData() => _saveQueue.add(() async {
        final previousSettings = AppSettings.fromJson(_settings.toJson());
        final apiSecret = _generateSecret();
        final defaults = AppSettings(apiSecret: apiSecret);
        await _replaceVerifiedApiSecret(apiSecret, defaults);
        try {
          await _persistSettings(defaults);
        } catch (error, stackTrace) {
          try {
            await _writeVerifiedApiSecret(previousSettings.apiSecret);
            _settings = previousSettings;
          } catch (rollbackError) {
            throw StateError(
              'Reset settings commit failed ($error) and API secret rollback '
              'failed ($rollbackError)',
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }

        final failures = <String>[];
        final names = [
          'subscriptions.json',
          'subscription_cache.yaml',
          'config.yaml',
          'country.mmdb',
          'geoip.metadb',
          'ssrvpn.log',
          'ssrvpn.log.old',
        ];
        for (final name in names) {
          final path = '$_dataDir${Platform.pathSeparator}$name';
          try {
            final type = await FileSystemEntity.type(path, followLinks: false);
            if (type == FileSystemEntityType.notFound) continue;
            if (type != FileSystemEntityType.file &&
                type != FileSystemEntityType.link) {
              throw FileSystemException('expected a file', path);
            }
            await File(path).delete();
          } catch (error) {
            failures.add('$name: $error');
          }
        }

        final tempPath = '$_dataDir${Platform.pathSeparator}tmp';
        try {
          final type =
              await FileSystemEntity.type(tempPath, followLinks: false);
          if (type == FileSystemEntityType.directory) {
            await Directory(tempPath).delete(recursive: true);
          } else if (type != FileSystemEntityType.notFound) {
            throw FileSystemException('expected a directory', tempPath);
          }
        } catch (error) {
          failures.add('tmp: $error');
        }

        notifyListeners();
        if (failures.isNotEmpty) {
          throw StateError(
              'App data reset was incomplete: ${failures.join('; ')}');
        }
      });

  Future<void> updateProxyPort(int port) async {
    await _updateSettings((settings) => settings.proxyPort = port);
  }

  Future<void> updateSocksPort(int port) async {
    await _updateSettings((settings) => settings.socksPort = port);
  }

  Future<void> updateApiPort(int port) async {
    await _updateSettings((settings) => settings.apiPort = port);
  }

  Future<void> updateApiSecret(String secret) async {
    final apiSecret = secret.isEmpty ? _generateSecret() : secret;
    await _saveQueue.add(() async {
      final candidate = _settings.copyWith(apiSecret: apiSecret);
      await _replaceVerifiedApiSecret(apiSecret, candidate);
      notifyListeners();
    });
  }

  Future<void> updateProxyMode(ProxyMode mode) async {
    await _updateSettings((settings) => settings.proxyMode = mode);
  }

  Future<void> updateTunStack(String stack) async {
    await _updateSettings((settings) => settings.tunStack = stack);
  }

  Future<void> updateEnableTun(bool enable) async {
    await _updateSettings((settings) => settings.enableTun = enable);
  }

  Future<void> updateLatencyTestUrl(String url) async {
    await _updateSettings((settings) => settings.latencyTestUrl = url);
  }

  Future<void> updateLatencyTestTimeout(int ms) async {
    await _updateSettings((settings) => settings.latencyTestTimeout = ms);
  }

  Future<void> updateForceProxySites(List<String> sites) async {
    await _updateSettings(
      (settings) => settings.forceProxySites =
          AppSettings.normalizeForceProxySites(sites),
    );
  }

  Future<void> updateForceDirectSites(List<String> sites) async {
    await _updateSettings(
      (settings) => settings.forceDirectSites =
          AppSettings.normalizeForceDirectSites(sites),
    );
  }

  Future<void> updateLastSelectedNodeName(String nodeName) async {
    await _updateSettings((settings) {
      settings.lastSelectedNodeName =
          RuntimeConfigNamePolicy.canonicalName(nodeName);
      settings.lastSelectedNodeRenameId = '';
    });
  }

  Future<void> renameLastSelectedNode(
    String originalName,
    String updatedName,
  ) async {
    await _updateSettings((settings) {
      if (RuntimeConfigNamePolicy.canonicalName(
              settings.lastSelectedNodeName) !=
          RuntimeConfigNamePolicy.canonicalName(originalName)) {
        return;
      }
      settings.lastSelectedNodeName =
          RuntimeConfigNamePolicy.canonicalName(updatedName);
      settings.lastSelectedNodeRenameId = '';
    });
  }

  void _publishNodePreference(AppSettings value) {
    _settings = value;
    notifyListeners();
  }

  @override
  Future<void> withNodePreferenceRename(NodePreferenceRename change,
          Future<void> Function(NodePreferenceWrite) edit) =>
      _saveQueue.add(() => edit(NodePreferenceWrite(
          current: _settings,
          change: change,
          write: _persistSettings,
          publish: _publishNodePreference)));

  @override
  Future<void> recoverNodePreference(NodePreferenceRename change) =>
      _saveQueue.add(() => NodePreferenceWrite.recover(
          change: change,
          current: _settings,
          file: File(_settingsPath),
          write: _persistSettings,
          publish: _publishNodePreference));
}
