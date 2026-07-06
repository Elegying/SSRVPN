import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart' show AppLogger;
import '../models/app_settings.dart';

/// 设置管理服务 — Android 版本
///
/// 对应 macOS SettingsService，管理所有设置项的读写和持久化
///
/// apiSecret 使用 Android EncryptedSharedPreferences 存储（AES-256），
/// 通过 flutter_secure_storage 封装。
class SettingsService extends ChangeNotifier {
  static SettingsService? _instance;
  late AppSettings _settings;
  late String _configPath;

  /// Android Keystore backed secure storage.
  static const _secureStorage = FlutterSecureStorage();

  /// 安全存储中的 key
  static const _secretKey = 'api_secret';

  /// 旧版 Base64 前缀（用于迁移）
  static const _legacyPrefix = 'b64:';

  SettingsService._();

  AppSettings get settings => _settings;

  static Future<SettingsService> getInstance() async {
    if (_instance == null) {
      _instance = SettingsService._();
      await _instance!._init();
    }
    return _instance!;
  }

  Future<void> _init() async {
    _configPath = await _resolveConfigPath();
    await _migrateLegacySettingsFile();
    await _load();
  }

  /// ── apiSecret 安全存储 ──

  /// 从安全存储读取 apiSecret
  Future<String> _readApiSecret() async {
    try {
      return await _secureStorage.read(key: _secretKey) ?? '';
    } catch (_) {}
    return '';
  }

  /// 写入 apiSecret 到安全存储
  Future<void> _writeApiSecret(String value) async {
    try {
      if (value.isEmpty) {
        await _secureStorage.delete(key: _secretKey);
      } else {
        await _secureStorage.write(key: _secretKey, value: value);
      }
    } catch (_) {}
  }

  /// 清理旧版 SharedPreferences 中的 Base64 编码密钥
  Future<void> _migrateLegacySecret() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString('api_secret_enc');
      if (legacy == null || legacy.isEmpty) return;

      // 解码旧值
      String decoded;
      if (legacy.startsWith(_legacyPrefix)) {
        decoded = utf8.decode(
          base64Decode(legacy.substring(_legacyPrefix.length)),
        );
      } else {
        decoded = legacy; // 旧版明文
      }

      // 迁移到安全存储
      if (decoded.isNotEmpty) {
        await _writeApiSecret(decoded);
        _settings = _settings.copyWith(apiSecret: decoded);
      }

      // 删除旧 key
      await prefs.remove('api_secret_enc');
      AppLogger.info('Settings', 'apiSecret 已迁移至 EncryptedSharedPreferences');
    } catch (e) {
      AppLogger.warning('Settings', 'apiSecret 迁移失败: $e');
    }
  }

  /// ── 批量更新设置 ──

  Future<void> updateSettings(AppSettings newSettings) async {
    final secret = newSettings.apiSecret.isNotEmpty
        ? newSettings.apiSecret
        : _settings.apiSecret;
    _settings = newSettings.copyWith(
      apiSecret: secret.isNotEmpty ? secret : _generateSecret(),
    );
    await _save();
    notifyListeners();
  }

  /// ── 单项设置更新 ──

  Future<void> setProxyMode(String mode) async {
    final pm = mode == 'global' ? ProxyMode.global : ProxyMode.rule;
    if (_settings.proxyMode == pm) return;
    _settings = _settings.copyWith(proxyMode: pm);
    await _save();
    notifyListeners();
  }

  Future<void> setTunEnabled(bool value) async {
    if (_settings.enableTun == value) return;
    _settings = _settings.copyWith(enableTun: value);
    await _save();
    notifyListeners();
  }

  Future<void> setLastSelectedNodeName(String name) async {
    if (_settings.lastSelectedNodeName == name) return;
    _settings = _settings.copyWith(lastSelectedNodeName: name);
    await _save();
    notifyListeners();
  }

  /// 重命名上次选择的节点
  Future<void> renameLastSelectedNode(String oldName, String newName) async {
    if (_settings.lastSelectedNodeName == oldName) {
      _settings = _settings.copyWith(lastSelectedNodeName: newName);
      await _save();
      notifyListeners();
    }
  }

  Future<void> setForceProxySites(List<String> sites) async {
    _settings = _settings.copyWith(forceProxySites: sites);
    await _save();
    notifyListeners();
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
      } catch (e) {
        AppLogger.warning('Settings', '加载失败: $e');
        _settings = AppSettings();
      }
    } else {
      _settings = AppSettings();
    }

    // 迁移：从旧 JSON 明文读取 apiSecret 并写入安全存储
    await _migrateApiSecret();
    if (_settings.apiSecret.isEmpty) {
      _settings = _settings.copyWith(apiSecret: _generateSecret());
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

  /// 迁移：旧 Base64/明文 apiSecret → EncryptedSharedPreferences
  Future<void> _migrateApiSecret() async {
    try {
      // 1) 从安全存储读取，如果已有则无需迁移
      final existing = await _readApiSecret();
      if (existing.isNotEmpty) {
        _settings = _settings.copyWith(apiSecret: existing);
        return;
      }

      // 2) 尝试从旧 SharedPreferences 迁移
      await _migrateLegacySecret();

      // 3) 从旧 JSON 明文迁移（首次安装后旧版本数据）
      if (_settings.apiSecret.isNotEmpty) {
        await _writeApiSecret(_settings.apiSecret);
        AppLogger.info('Settings', 'apiSecret 已迁移至 EncryptedSharedPreferences');
      }
    } catch (e) {
      AppLogger.warning('Settings', 'apiSecret 迁移失败: $e');
    }
  }

  Future<void> _save() async {
    try {
      final file = File(_configPath);
      await file.parent.create(recursive: true);

      // apiSecret 不写入 JSON 明文
      final jsonMap = _settings.toJson();
      jsonMap.remove('apiSecret');

      final jsonStr = await Isolate.run(() => jsonEncode(jsonMap));
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonStr, flush: true);
      await temp.rename(file.path);

      // apiSecret 写入安全存储
      await _writeApiSecret(_settings.apiSecret);
    } catch (e) {
      AppLogger.warning('Settings', '保存失败: $e');
    }
  }

  /// apiSecret getter — 从安全存储读取
  Future<String> getApiSecret() => _readApiSecret();

  /// apiSecret setter — 写入安全存储
  Future<void> setApiSecret(String value) async {
    _settings = _settings.copyWith(
      apiSecret: value.isNotEmpty ? value : _generateSecret(),
    );
    await _save();
    notifyListeners();
  }

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance = null;
  }
}
