import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show AppLogger, AsyncLazy, RecoveringSerialQueue;
import '../models/app_settings.dart';

/// 设置管理服务 — Android 版本
///
/// 对应 macOS SettingsService，管理所有设置项的读写和持久化
///
/// apiSecret 使用 Android Keystore 支持的 AES-GCM 安全存储，
/// 通过 flutter_secure_storage 封装。
class SettingsService extends ChangeNotifier {
  static final _instance = AsyncLazy<SettingsService>();
  late AppSettings _settings;
  late String _configPath;
  final Future<String?> Function() _readSecureApiSecret;
  final Future<void> Function(String value) _writeSecureApiSecret;
  final RecoveringSerialQueue _saveQueue = RecoveringSerialQueue();

  /// Android Keystore backed secure storage.
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );

  /// 安全存储中的 key
  static const _secretKey = 'api_secret';

  /// 旧版 Base64 前缀（用于迁移）
  static const _legacyPrefix = 'b64:';

  SettingsService._({
    Future<String?> Function()? readApiSecret,
    Future<void> Function(String value)? writeApiSecret,
  })  : _readSecureApiSecret = readApiSecret ?? _readDefaultApiSecret,
        _writeSecureApiSecret = writeApiSecret ?? _writeDefaultApiSecret;

  AppSettings get settings => _settings;

  static Future<SettingsService> getInstance() => _instance.get(() async {
        final service = SettingsService._();
        await service._init();
        return service;
      });

  @visibleForTesting
  static Future<SettingsService> createForTesting({
    required String configPath,
    required Future<String?> Function() readApiSecret,
    required Future<void> Function(String value) writeApiSecret,
  }) async {
    final service = SettingsService._(
      readApiSecret: readApiSecret,
      writeApiSecret: writeApiSecret,
    );
    service._configPath = configPath;
    await service._load();
    return service;
  }

  Future<void> _init() async {
    _configPath = await _resolveConfigPath();
    await _migrateLegacySettingsFile();
    await _load();
  }

  /// ── apiSecret 安全存储 ──

  static Future<String?> _readDefaultApiSecret() =>
      _secureStorage.read(key: _secretKey);

  static Future<void> _writeDefaultApiSecret(String value) async {
    if (value.isEmpty) {
      await _secureStorage.delete(key: _secretKey);
    } else {
      await _secureStorage.write(key: _secretKey, value: value);
    }
  }

  /// 从安全存储读取 apiSecret
  Future<String> _readApiSecret() async {
    return await _readSecureApiSecret() ?? '';
  }

  /// 写入 apiSecret 到安全存储
  Future<void> _writeApiSecret(String value) => _writeSecureApiSecret(value);

  /// 清理旧版 SharedPreferences 中的 Base64 编码密钥
  Future<bool> _migrateLegacySecret() async {
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString('api_secret_enc');
    if (legacy == null || legacy.isEmpty) return false;

    // 解码旧值
    final String decoded;
    if (legacy.startsWith(_legacyPrefix)) {
      decoded = utf8.decode(
        base64Decode(legacy.substring(_legacyPrefix.length)),
      );
    } else {
      decoded = legacy; // 旧版明文
    }
    if (decoded.isEmpty) return false;

    // 只有安全存储写入成功后，才清理旧 key。
    await _writeApiSecret(decoded);
    _settings = _settings.copyWith(apiSecret: decoded);
    final removed = await _removeLegacySecretCopy(prefs);
    if (removed) {
      AppLogger.info('Settings', 'apiSecret 已迁移至 Android Keystore 安全存储');
    }
    return true;
  }

  Future<bool> _removeLegacySecretCopy(SharedPreferences prefs) async {
    if (!prefs.containsKey('api_secret_enc')) return false;
    var removed = false;
    try {
      removed = await prefs.remove('api_secret_enc');
      if (!removed) {
        AppLogger.warning('Settings', 'apiSecret 旧存储清理失败');
      }
    } catch (_) {
      // 安全副本已经确认写入；清理失败时保留旧值，避免数据丢失。
      AppLogger.warning('Settings', 'apiSecret 旧存储清理失败');
    }
    return removed;
  }

  /// ── 批量更新设置 ──

  Future<void> updateSettings(AppSettings newSettings) {
    // AppSettings is mutable. Snapshot the caller-owned value before it waits
    // in the serial queue, and keep API-secret rotation on setApiSecret so a
    // normal settings write never spans JSON and Android Keystore storage.
    final snapshot = AppSettings.fromJson(newSettings.toJson());
    return _saveQueue.add(() async {
      final candidate = snapshot.copyWith(
        apiSecret: _settings.apiSecret,
      );
      if (candidate == _settings) return;
      await _saveSettings(candidate);
      _settings = candidate;
      notifyListeners();
    });
  }

  /// ── 单项设置更新 ──

  Future<void> setProxyMode(String mode) {
    final pm = mode == 'global' ? ProxyMode.global : ProxyMode.rule;
    return _updateSettings((settings) => settings.copyWith(proxyMode: pm));
  }

  Future<void> setTunEnabled(bool value) =>
      _updateSettings((settings) => settings.copyWith(enableTun: value));

  Future<void> setLastSelectedNodeName(String name) => _updateSettings(
        (settings) => settings.copyWith(lastSelectedNodeName: name),
      );

  /// 重命名上次选择的节点
  Future<void> renameLastSelectedNode(String oldName, String newName) =>
      _updateSettings((settings) {
        if (settings.lastSelectedNodeName != oldName) return settings;
        return settings.copyWith(lastSelectedNodeName: newName);
      });

  Future<void> setForceProxySites(List<String> sites) {
    final snapshot = AppSettings.normalizeForceProxySites(
      List<String>.of(sites),
    );
    return _updateSettings(
      (settings) => settings.copyWith(forceProxySites: snapshot),
    );
  }

  /// 别名：供 home_screen 使用
  Future<void> updateForceProxySites(List<String> sites) =>
      setForceProxySites(sites);

  /// ── 持久化 ──

  Future<String> _resolveConfigPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}settings.json';
  }

  Future<void> _migrateLegacySettingsFile() async {
    final target = File(_configPath);
    if (await target.exists()) return;

    for (final path in _legacyConfigPathCandidates()) {
      final source = File(path);
      if (!await source.exists()) continue;
      try {
        await target.parent.create(recursive: true);
        await source.copy(target.path);
        return;
      } catch (_) {}
    }
  }

  List<String> _legacyConfigPathCandidates() {
    final candidates = <String>[];
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      candidates.add('$home/.ssrvpn/settings.json');
    }
    candidates.addAll(const [
      '/data/data/com.ssrvpn.android/files/.ssrvpn/settings.json',
      '/data/data/com.ssrvpn.app/files/.ssrvpn/settings.json',
    ]);
    return candidates;
  }

  Future<void> _load() async {
    final file = File(_configPath);
    if (await file.exists()) {
      try {
        final content = await Isolate.run(() => file.readAsString());
        final json = jsonDecode(content) as Map<String, dynamic>;
        _settings = AppSettings.fromJson(json);
      } catch (_) {
        // JSON 解析异常可能包含原始内容，避免把旧版明文密钥写入日志。
        AppLogger.warning('Settings', '加载失败');
        _settings = AppSettings();
      }
    } else {
      _settings = AppSettings();
    }

    // 迁移：从旧 JSON 明文读取 apiSecret 并写入安全存储
    final shouldScrubJsonSecret = await _migrateApiSecret();
    if (_settings.apiSecret.isEmpty) {
      _settings = _settings.copyWith(apiSecret: _generateSecret());
      await _save(persistApiSecret: true);
    } else if (shouldScrubJsonSecret) {
      await _save();
    }
  }

  String _generateSecret() {
    final rand = Random.secure();
    return List.generate(
      16,
      (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// 迁移：旧 Base64/明文 apiSecret → Android Keystore 安全存储
  Future<bool> _migrateApiSecret() async {
    final hadJsonSecret = _settings.apiSecret.isNotEmpty;
    try {
      // 1) 从安全存储读取，如果已有则无需迁移
      final existing = await _readApiSecret();
      if (existing.isNotEmpty) {
        _settings = _settings.copyWith(apiSecret: existing);
        final prefs = await SharedPreferences.getInstance();
        await _removeLegacySecretCopy(prefs);
        return hadJsonSecret;
      }

      // 2) 尝试从旧 SharedPreferences 迁移
      final migratedLegacySecret = await _migrateLegacySecret();

      // 3) 从旧 JSON 明文迁移（首次安装后旧版本数据）
      if (!migratedLegacySecret && _settings.apiSecret.isNotEmpty) {
        await _writeApiSecret(_settings.apiSecret);
        AppLogger.info('Settings', 'apiSecret 已迁移至 Android Keystore 安全存储');
      }
      return hadJsonSecret;
    } catch (_) {
      AppLogger.warning('Settings', 'apiSecret 迁移失败');
      rethrow;
    }
  }

  Future<void> _updateSettings(
    AppSettings Function(AppSettings settings) update,
  ) {
    return _saveQueue.add(() async {
      final candidate = update(_settings);
      if (candidate == _settings) return;
      await _saveSettings(candidate);
      _settings = candidate;
      notifyListeners();
    });
  }

  Future<void> _save({bool persistApiSecret = false}) =>
      _saveSettings(_settings, persistApiSecret: persistApiSecret);

  Future<void> _saveSettings(
    AppSettings settings, {
    bool persistApiSecret = false,
  }) async {
    try {
      final file = File(_configPath);
      await file.parent.create(recursive: true);

      // apiSecret 不写入 JSON 明文
      final jsonMap = settings.toJson();
      jsonMap.remove('apiSecret');

      final jsonStr = await Isolate.run(() => jsonEncode(jsonMap));
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonStr, flush: true);
      await temp.rename(file.path);

      if (persistApiSecret) {
        await _writeApiSecret(settings.apiSecret);
      }
    } catch (_) {
      AppLogger.warning('Settings', '保存失败');
      rethrow;
    }
  }

  /// apiSecret getter — 从安全存储读取
  Future<String> getApiSecret() => _readApiSecret();

  /// apiSecret setter — 写入安全存储
  Future<void> setApiSecret(String value) => _saveQueue.add(() async {
        final candidate = _settings.copyWith(
          apiSecret: value.isNotEmpty ? value : _generateSecret(),
        );
        await _persistApiSecret(candidate.apiSecret);
        _settings = candidate;
        notifyListeners();
      });

  Future<void> _persistApiSecret(String value) async {
    try {
      await _writeApiSecret(value);
    } catch (_) {
      AppLogger.warning('Settings', '保存失败');
      rethrow;
    }
  }

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance.reset();
  }
}
