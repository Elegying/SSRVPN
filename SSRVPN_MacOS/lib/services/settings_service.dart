import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show AsyncLazy, RecoveringSerialQueue;
import '../models/app_settings.dart';

typedef _OpenDirectoryNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenDirectoryDart = int Function(Pointer<Utf8>, int);
typedef _FileDescriptorNative = Int32 Function(Int32);
typedef _FileDescriptorDart = int Function(int);

class _LegacyPreferencesSnapshot {
  const _LegacyPreferencesSnapshot({
    required this.apiSecret,
    this.settings,
    this.parseError,
  });

  final String apiSecret;
  final AppSettings? settings;
  final Object? parseError;
}

/// 设置持久化服务。
///
/// macOS 使用 Application Support 下的 JSON 文件，与 Windows 客户端保持同一
/// 数据结构，方便 UI 和启动流程复用。
class SettingsService extends ChangeNotifier {
  static final _instance = AsyncLazy<SettingsService>();
  late AppSettings _settings;
  late String _settingsPath;
  late String _dataDir;
  String? _storageNotice;
  final Future<String?> Function()? _readApiSecretOverride;
  final Future<void> Function(String value)? _writeApiSecretOverride;
  final Future<void> Function(AppSettings settings)? _writeSettingsOverride;

  static final _libc = DynamicLibrary.process();
  static final _openDirectory =
      _libc.lookupFunction<_OpenDirectoryNative, _OpenDirectoryDart>('open');
  static final _fsync =
      _libc.lookupFunction<_FileDescriptorNative, _FileDescriptorDart>('fsync');
  static final _close =
      _libc.lookupFunction<_FileDescriptorNative, _FileDescriptorDart>('close');

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

  String get _apiSecretPath => '$_dataDir${Platform.pathSeparator}.api-secret';

  Future<String?> _readApiSecret() =>
      _readApiSecretOverride?.call() ?? _readDefaultApiSecret();

  Future<void> _writeApiSecret(String value) =>
      _writeApiSecretOverride?.call(value) ?? _writeDefaultApiSecret(value);

  Future<void> _chmod(String mode, String path) async {
    final result = await Process.run('/bin/chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'chmod $mode failed: ${result.stderr}',
        path,
      );
    }
  }

  Future<String?> _readDefaultApiSecret() async {
    final type =
        await FileSystemEntity.type(_apiSecretPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'API secret path must be a regular file',
        _apiSecretPath,
      );
    }

    final file = File(_apiSecretPath);
    var stat = await file.stat();
    if ((stat.mode & 0x1ff) != 0x180) {
      await _chmod('600', file.path);
      stat = await file.stat();
      if ((stat.mode & 0x1ff) != 0x180) {
        throw FileSystemException(
          'API secret permissions must be 0600',
          file.path,
        );
      }
    }

    final value = await file.readAsString();
    if (value.isEmpty) return null;
    if (value.length > 4096) {
      throw const FormatException('API secret file is unexpectedly large');
    }
    return value;
  }

  Future<void> _writeDefaultApiSecret(String value) async {
    if (value.isEmpty || value.length > 4096) {
      throw ArgumentError.value(value.length, 'value', 'invalid API secret');
    }

    await _ensurePrivateDataDirectory(_dataDir);
    final temp = File(
      '$_apiSecretPath.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    RandomAccessFile? handle;
    try {
      await temp.create(exclusive: true);
      await _chmod('600', temp.path);
      handle = await temp.open(mode: FileMode.writeOnly);
      await handle.writeString(value);
      await handle.flush();
      await handle.close();
      handle = null;
      await temp.rename(_apiSecretPath);
      _syncDataDirectory();

      final stat = await File(_apiSecretPath).stat();
      if ((stat.mode & 0x1ff) != 0x180) {
        throw FileSystemException(
          'API secret permissions must be 0600',
          _apiSecretPath,
        );
      }
    } finally {
      await handle?.close();
      if (await temp.exists()) await temp.delete();
    }
  }

  void _syncDataDirectory() {
    if (!Platform.isMacOS) return;
    final path = _dataDir.toNativeUtf8(allocator: calloc);
    var descriptor = -1;
    try {
      descriptor = _openDirectory(path, 0);
      if (descriptor < 0) {
        throw FileSystemException(
          'failed to open the data directory for fsync',
          _dataDir,
        );
      }
      if (_fsync(descriptor) != 0) {
        throw FileSystemException(
          'failed to fsync the data directory',
          _dataDir,
        );
      }
    } finally {
      if (descriptor >= 0) _close(descriptor);
      calloc.free(path);
    }
  }

  Future<void> _removeApiSecretTemporaryFiles() async {
    final directoryType =
        await FileSystemEntity.type(_dataDir, followLinks: false);
    if (directoryType == FileSystemEntityType.notFound) return;
    if (directoryType != FileSystemEntityType.directory) {
      throw FileSystemException(
        'SSRVPN data path must be a real directory',
        _dataDir,
      );
    }

    await for (final entry in Directory(_dataDir).list(followLinks: false)) {
      final name = entry.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('.api-secret.tmp.')) continue;
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.link) {
        throw FileSystemException(
          'API secret temporary path must be a file',
          entry.path,
        );
      }
      await File(entry.path).delete();
    }
  }

  Future<String> _resolveDataDirectory() async {
    if (Platform.isMacOS) {
      final supportDir = await getApplicationSupportDirectory();
      final dataDir = '${supportDir.path}${Platform.pathSeparator}SSRVPN';
      await _verifyWritableDirectory(dataDir);
      return dataDir;
    }

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
    await _ensurePrivateDataDirectory(path);
    final probe = File(
      '$path${Platform.pathSeparator}.write_test_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await probe.writeAsString('ok', flush: true);
    } finally {
      if (await probe.exists()) await probe.delete();
    }
  }

  Future<void> _ensurePrivateDataDirectory(String path) async {
    var type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await Directory(path).create(recursive: true);
      type = await FileSystemEntity.type(path, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'SSRVPN data path must be a real directory',
        path,
      );
    }
    await _chmod('700', path);
  }

  Future<void> _migratePortableData(
    String portableDir,
    String fallbackDir,
  ) async {
    final source = Directory(portableDir);
    if (!await source.exists()) return;

    const fileNames = [
      'settings.json',
      'subscriptions.json',
      'subscription_cache.yaml',
      'config.yaml',
      'country.mmdb',
      'geoip.metadb',
    ];
    for (final name in fileNames) {
      final sourceFile = File('$portableDir${Platform.pathSeparator}$name');
      final targetFile = File('$fallbackDir${Platform.pathSeparator}$name');
      if (!await sourceFile.exists() || await targetFile.exists()) continue;
      try {
        await sourceFile.copy(targetFile.path);
      } catch (_) {
        // A single locked cache file should not block application startup.
      }
    }
  }

  Future<void> _load() async {
    await _removeApiSecretTemporaryFiles();
    final file = File(_settingsPath);
    final hadSettingsFile = await file.exists();
    var modernSettingsValid = false;
    var jsonSecret = '';
    Map<String, dynamic>? decodedSettings;
    if (hadSettingsFile) {
      try {
        final content = await file.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('settings.json must be a JSON object');
        }
        decodedSettings = decoded;
        jsonSecret = _extractApiSecret(decoded);
        _settings = AppSettings.fromJson(decoded);
        modernSettingsValid = true;
      } catch (e) {
        if (jsonSecret.isNotEmpty) {
          final storedSecret = await _readApiSecret();
          if (storedSecret == null || storedSecret.isEmpty) {
            await _writeVerifiedApiSecret(jsonSecret);
          }
        }
        await _backupBadFile(
          file,
          'settings.json could not be parsed (${e.runtimeType})',
          decoded: decodedSettings,
        );
        _settings = AppSettings();
      }
    } else {
      _settings = AppSettings();
    }

    final storedSecret = await _readApiSecret();
    if (modernSettingsValid &&
        ((storedSecret != null && storedSecret.isNotEmpty) ||
            jsonSecret.isNotEmpty)) {
      final effectiveSecret = storedSecret != null && storedSecret.isNotEmpty
          ? storedSecret
          : jsonSecret;
      if (storedSecret == null || storedSecret.isEmpty) {
        await _writeVerifiedApiSecret(effectiveSecret);
      }
      _settings = _settings.copyWith(apiSecret: effectiveSecret);
      if (jsonSecret.isNotEmpty) {
        await _writeSettingsFile(_settings);
      }
      await _removeLegacySharedPreferences();
      return;
    }

    final legacySnapshot = await _loadLegacySharedPreferences();
    if (legacySnapshot?.parseError case final error?) {
      throw FormatException(
        'legacy app_settings could not be parsed (${error.runtimeType})',
      );
    }
    if (!hadSettingsFile) {
      _settings = legacySnapshot?.settings ?? AppSettings();
    }

    if (jsonSecret.isEmpty) jsonSecret = _settings.apiSecret;
    final legacySecret =
        jsonSecret.isNotEmpty ? jsonSecret : (legacySnapshot?.apiSecret ?? '');
    if (storedSecret != null && storedSecret.isNotEmpty) {
      _settings = _settings.copyWith(apiSecret: storedSecret);
    } else if (legacySecret.isNotEmpty) {
      await _writeVerifiedApiSecret(legacySecret);
      _settings = _settings.copyWith(apiSecret: legacySecret);
    } else {
      final generatedSecret = _generateSecret();
      await _writeVerifiedApiSecret(generatedSecret);
      _settings = _settings.copyWith(apiSecret: generatedSecret);
    }

    if (jsonSecret.isNotEmpty || !await file.exists()) {
      await _writeSettingsFile(_settings);
    }
    await _removeLegacySharedPreferences();
  }

  Future<void> _writeVerifiedApiSecret(String value) async {
    await _writeApiSecret(value);
    if (await _readApiSecret() != value) {
      throw StateError('macOS secret store did not retain the API secret');
    }
  }

  Future<void> _replaceVerifiedApiSecret(
    String value,
    AppSettings candidate,
  ) async {
    final previousSecret = _settings.apiSecret;
    try {
      await _writeApiSecret(value);
      if (await _readApiSecret() != value) {
        throw StateError('macOS secret store did not retain the API secret');
      }
      _settings = candidate;
    } catch (error, stackTrace) {
      try {
        await _writeApiSecret(previousSecret);
        if (await _readApiSecret() != previousSecret) {
          throw StateError('macOS secret store rollback verification failed');
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

  String _extractApiSecret(Map<String, dynamic> decoded) {
    final value = decoded['apiSecret'];
    return value is String ? value : '';
  }

  Future<_LegacyPreferencesSnapshot?> _loadLegacySharedPreferences() async {
    if (!Platform.isMacOS) return null;
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('app_settings');
    if (jsonStr == null || jsonStr.trim().isEmpty) return null;

    Object? decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (error) {
      return _LegacyPreferencesSnapshot(apiSecret: '', parseError: error);
    }
    if (decoded is! Map<String, dynamic>) {
      return const _LegacyPreferencesSnapshot(
        apiSecret: '',
        parseError: FormatException('app_settings must be a JSON object'),
      );
    }

    final apiSecret = _extractApiSecret(decoded);
    try {
      return _LegacyPreferencesSnapshot(
        apiSecret: apiSecret,
        settings: AppSettings.fromJson(decoded),
      );
    } catch (error) {
      return _LegacyPreferencesSnapshot(
        apiSecret: apiSecret,
        parseError: error,
      );
    }
  }

  Future<void> _removeLegacySharedPreferences() async {
    if (!Platform.isMacOS) return;
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey('app_settings')) return;
    if (!await prefs.remove('app_settings')) {
      throw StateError('failed to remove legacy app_settings preferences');
    }
  }

  Future<void> _backupBadFile(
    File file,
    String reason, {
    required Map<String, dynamic>? decoded,
  }) async {
    if (!await file.exists()) return;
    if (decoded == null) {
      throw FormatException(
        'settings.json could not be safely scrubbed; startup stopped '
        'instead of archiving an unsanitized copy ($reason)',
      );
    }

    final sanitized = Map<String, dynamic>.from(decoded)..remove('apiSecret');
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '');
    final backup = File('${file.path}.bad-$stamp');
    final scrubbedTemp = File(
      '${file.path}.scrubbed.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await scrubbedTemp.writeAsString(jsonEncode(sanitized), flush: true);
      await scrubbedTemp.rename(file.path);
      _syncDataDirectory();
      await file.rename(backup.path);
      await File('${backup.path}.reason.txt')
          .writeAsString(reason, flush: true);
      _syncDataDirectory();
    } finally {
      if (await scrubbedTemp.exists()) await scrubbedTemp.delete();
    }
  }

  String _generateSecret() {
    final rand = Random.secure();
    return List.generate(
        16, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  final RecoveringSerialQueue _saveQueue = RecoveringSerialQueue();

  Future<void> _writeSettingsFile(AppSettings settings) async {
    final override = _writeSettingsOverride;
    if (override != null) {
      await override(settings);
      return;
    }
    final persisted = settings.toJson()..remove('apiSecret');
    await _writeSettingsBytes(utf8.encode(jsonEncode(persisted)));
  }

  Future<void> _writeSettingsBytes(List<int> bytes) async {
    final file = File(_settingsPath);
    await file.parent.create(recursive: true);
    final temp = File(
      '$_settingsPath.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    RandomAccessFile? handle;
    try {
      await temp.create(exclusive: true);
      handle = await temp.open(mode: FileMode.writeOnly);
      await handle.writeFrom(bytes);
      await handle.flush();
      await handle.close();
      handle = null;
      await temp.rename(file.path);
      _syncDataDirectory();
    } finally {
      await handle?.close();
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> save() {
    return _saveQueue.add(() async {
      final snapshot = AppSettings.fromJson(_settings.toJson());
      await _writeSettingsFile(snapshot);
      notifyListeners();
    });
  }

  Future<void> _updateSettings(void Function(AppSettings) update) {
    return _saveQueue.add(() async {
      final candidate = AppSettings.fromJson(_settings.toJson());
      update(candidate);
      await _writeSettingsFile(candidate);
      _settings = candidate;
      notifyListeners();
    });
  }

  Future<void> flush() => _saveQueue.flush();

  Future<void> _rollbackResetCommit({
    required AppSettings previousSettings,
    required String previousSecret,
    required List<int>? previousSettingsBytes,
  }) async {
    final failures = <String>[];
    try {
      final file = File(_settingsPath);
      if (previousSettingsBytes == null) {
        if (await file.exists()) {
          await file.delete();
          _syncDataDirectory();
        }
      } else {
        await _writeSettingsBytes(previousSettingsBytes);
      }
    } catch (error) {
      failures.add('settings: $error');
    }

    try {
      await _writeApiSecret(previousSecret);
      if (await _readApiSecret() != previousSecret) {
        throw StateError('API secret rollback verification failed');
      }
    } catch (error) {
      failures.add('API secret: $error');
    }

    _settings = previousSettings;
    if (failures.isNotEmpty) {
      throw StateError('reset rollback was incomplete: ${failures.join('; ')}');
    }
  }

  Future<void> resetAppData() => _saveQueue.add(() async {
        final previousSettings = AppSettings.fromJson(_settings.toJson());
        final settingsFile = File(_settingsPath);
        final previousSettingsBytes = await settingsFile.exists()
            ? await settingsFile.readAsBytes()
            : null;
        final previousSecret = previousSettings.apiSecret;
        final apiSecret = _generateSecret();
        final defaults = AppSettings(apiSecret: apiSecret);
        var secretCommitted = false;
        try {
          await _replaceVerifiedApiSecret(apiSecret, defaults);
          secretCommitted = true;
          await _writeSettingsFile(defaults);
        } catch (error, stackTrace) {
          if (!secretCommitted) {
            Error.throwWithStackTrace(error, stackTrace);
          }
          try {
            await _rollbackResetCommit(
              previousSettings: previousSettings,
              previousSecret: previousSecret,
              previousSettingsBytes: previousSettingsBytes,
            );
          } catch (rollbackError) {
            throw StateError(
              'reset commit failed ($error) and rollback failed '
              '($rollbackError)',
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }

        final failures = <String>[];
        try {
          await _removeApiSecretTemporaryFiles();
        } catch (error) {
          failures.add('API secret temporary files: $error');
        }
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

  Future<void> updateTunMode(bool enabled) => updateEnableTun(enabled);

  Future<void> updateEnableSystemProxy(bool enabled) async {
    await _updateSettings((settings) => settings.enableTun = !enabled);
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

  Future<void> updateLastSelectedNode(String nodeName) =>
      updateLastSelectedNodeName(nodeName);

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
