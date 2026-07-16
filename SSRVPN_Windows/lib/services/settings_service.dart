import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show AsyncLazy, RecoveringSerialQueue;
import '../models/app_settings.dart';
import 'windows_dpapi_secret_store.dart';

/// 设置持久化服务 (Windows 便携版)
///
/// 使用 JSON 文件存储设置，放在 exe 同级目录下，支持绿色免安装。
class SettingsService extends ChangeNotifier {
  static const _apiSecretFileName = '.api-secret.dpapi';
  static const _portableMigrationMarkerName = '.portable-migration-v1';
  static const _portableDataFiles = [
    _apiSecretFileName,
    'settings.json',
    'subscriptions.json',
    'subscription_cache.yaml',
    'config.yaml',
    'country.mmdb',
    'geoip.metadb',
  ];
  static const _criticalPortableDataFiles = {
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
    final portableDir = '$exeDir${Platform.pathSeparator}ssrvpn';
    try {
      await _verifyWritableDirectory(portableDir);
      return portableDir;
    } catch (e) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData == null || localAppData.trim().isEmpty) {
        rethrow;
      }

      final fallbackDir =
          '$localAppData${Platform.pathSeparator}SSRVPN${Platform.pathSeparator}ssrvpn';
      await _verifyWritableDirectory(fallbackDir);
      await _migratePortableData(portableDir, fallbackDir);
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
  static Future<void> migratePortableDataForTesting(
    String portableDir,
    String fallbackDir,
  ) =>
      _migratePortableData(portableDir, fallbackDir);

  static Future<void> _migratePortableData(
    String portableDir,
    String fallbackDir,
  ) async {
    final source = Directory(portableDir);
    if (!await source.exists()) return;
    final migrationMarker = File(
      '$fallbackDir${Platform.pathSeparator}$_portableMigrationMarkerName',
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
        'Portable migration marker must be a regular file',
        migrationMarker.path,
      );
    }

    for (final name in _portableDataFiles) {
      final sourceFile = File('$portableDir${Platform.pathSeparator}$name');
      final targetFile = File('$fallbackDir${Platform.pathSeparator}$name');
      final critical = _criticalPortableDataFiles.contains(name);
      final sourceType =
          await FileSystemEntity.type(sourceFile.path, followLinks: false);
      if (sourceType == FileSystemEntityType.notFound) continue;
      if (sourceType != FileSystemEntityType.file) {
        if (critical) {
          throw FileSystemException(
            'Critical portable data must be a regular file',
            sourceFile.path,
          );
        }
        continue;
      }

      final targetType =
          await FileSystemEntity.type(targetFile.path, followLinks: false);
      if (targetType != FileSystemEntityType.notFound) {
        if (critical) {
          if (targetType != FileSystemEntityType.file) {
            throw FileSystemException(
              'Critical fallback data must be a regular file',
              targetFile.path,
            );
          }
          if (!listEquals(
            await sourceFile.readAsBytes(),
            await targetFile.readAsBytes(),
          )) {
            throw StateError(
              'Portable data conflicts with existing fallback $name',
            );
          }
        }
        continue;
      }

      try {
        await sourceFile.copy(targetFile.path);
        if (critical &&
            !listEquals(
              await sourceFile.readAsBytes(),
              await targetFile.readAsBytes(),
            )) {
          await targetFile.delete();
          throw StateError(
              'Portable data migration verification failed: $name');
        }
      } catch (error, stackTrace) {
        if (critical) {
          final partialType = await FileSystemEntity.type(
            targetFile.path,
            followLinks: false,
          );
          if (partialType == FileSystemEntityType.file ||
              partialType == FileSystemEntityType.link) {
            await targetFile.delete();
          }
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
      await _backupBadFile(
        file,
        badSettingsReason,
        decoded: decodedSettings,
      );
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
            'Windows secure storage did not retain the API secret');
      }
      _settings = candidate;
    } catch (error, stackTrace) {
      try {
        await _writeSecureApiSecret(previousSecret);
        if (await _readSecureApiSecret() != previousSecret) {
          throw StateError(
              'Windows secure storage rollback verification failed');
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
        ? <String, dynamic>{
            'originalContentOmitted': true,
            'reason': reason,
          }
        : (Map<String, dynamic>.from(decoded)..remove('apiSecret'));
    await backup.writeAsString(jsonEncode(sanitized), flush: true);
    await File('${backup.path}.reason.txt').writeAsString(reason, flush: true);
    await file.delete();
  }

  String _generateSecret() {
    final rand = Random.secure();
    return List.generate(
        16, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
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
            'App data reset was incomplete: ${failures.join('; ')}',
          );
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

  Future<void> updateLastSelectedNodeName(String nodeName) async {
    await _updateSettings(
      (settings) => settings.lastSelectedNodeName = nodeName,
    );
  }

  Future<void> renameLastSelectedNode(
    String originalName,
    String updatedName,
  ) async {
    if (_settings.lastSelectedNodeName != originalName) return;
    await _updateSettings(
      (settings) => settings.lastSelectedNodeName = updatedName,
    );
  }
}
