import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show AsyncLazy, RecoveringSerialQueue;
import '../models/app_settings.dart';

/// 设置持久化服务 (Windows 便携版)
///
/// 使用 JSON 文件存储设置，放在 exe 同级目录下，支持绿色免安装。
class SettingsService extends ChangeNotifier {
  static final _instance = AsyncLazy<SettingsService>();
  late AppSettings _settings;
  late String _settingsPath;
  late String _dataDir;
  String? _storageNotice;

  SettingsService._();

  @visibleForTesting
  static SettingsService createForTesting({
    required AppSettings settings,
    required String dataDir,
    required String settingsPath,
  }) {
    return SettingsService._()
      .._settings = settings
      .._dataDir = dataDir
      .._settingsPath = settingsPath;
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
    final file = File(_settingsPath);
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('settings.json must be a JSON object');
        }
        _settings = AppSettings.fromJson(decoded);
      } catch (e) {
        await _backupBadFile(file, 'settings.json parse failed: $e');
        _settings = AppSettings();
      }
    } else {
      _settings = AppSettings();
    }

    // 首次启动生成随机 API secret
    if (_settings.apiSecret.isEmpty) {
      _settings.apiSecret = _generateSecret();
      await save();
    }
  }

  Future<void> _backupBadFile(File file, String reason) async {
    try {
      if (!await file.exists()) return;
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      final backup = File('${file.path}.bad-$stamp');
      await file.rename(backup.path);
      await File('${backup.path}.reason.txt').writeAsString(reason);
    } catch (_) {}
  }

  String _generateSecret() {
    final rand = Random.secure();
    return List.generate(
        16, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  final RecoveringSerialQueue _saveQueue = RecoveringSerialQueue();

  Future<void> _writeSettingsFile(AppSettings settings) async {
    final settingsJson = jsonEncode(settings.toJson());
    final file = File(_settingsPath);
    await file.parent.create(recursive: true);
    final temp = File(
      '$_settingsPath.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(settingsJson, flush: true);
    await temp.rename(file.path);
  }

  Future<void> save() {
    final snapshot = AppSettings.fromJson(_settings.toJson());
    return _saveQueue.add(() async {
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

  Future<void> resetAppData() async {
    await flush();

    final names = [
      'settings.json',
      'subscriptions.json',
      'subscription_cache.yaml',
      'config.yaml',
      'country.mmdb',
      'geoip.metadb',
      'ssrvpn.log',
      'ssrvpn.log.old',
    ];

    for (final name in names) {
      final file = File('$_dataDir${Platform.pathSeparator}$name');
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    final tempDir = Directory('$_dataDir${Platform.pathSeparator}tmp');
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}

    _settings = AppSettings()..apiSecret = _generateSecret();
    await save();
    notifyListeners();
  }

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
    await _updateSettings((settings) => settings.apiSecret = secret);
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
