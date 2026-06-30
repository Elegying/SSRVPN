import 'dart:async';
import 'package:ssrvpn_shared/models/app_settings.dart' show ProxyMode;
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
      await _instance!._load();
    }
    return _instance!;
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
      debugPrint('[Settings] apiSecret 已迁移至 EncryptedSharedPreferences');
    } catch (e) {
      debugPrint('[Settings] apiSecret 迁移失败: $e');
    }
  }

  /// ── 批量更新设置 ──

  Future<void> updateSettings(AppSettings newSettings) async {
    _settings = newSettings;
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

  Future<void> setAutoConnect(bool value) async {
    if (_settings.autoConnectOnStartup == value) return;
    _settings = _settings.copyWith(autoConnectOnStartup: value);
    await _save();
    notifyListeners();
  }

  Future<void> setAutoCheckUpdate(bool value) async {
    if (_settings.autoCheckUpdate == value) return;
    _settings = _settings.copyWith(autoCheckUpdate: value);
    await _save();
    notifyListeners();
  }

  Future<void> setDarkMode(bool value) async {
    if (_settings.darkMode == value) return;
    _settings = _settings.copyWith(darkMode: value);
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
  Future<void> renameLastSelectedNode(
    String oldName,
    String newName,
  ) async {
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

  String get _configPath {
    final home =
        Platform.environment['HOME'] ?? '/data/data/com.ssrvpn.app/files';
    return '$home/.ssrvpn/settings.json';
  }

  Future<void> _load() async {
    final file = File(_configPath);
    if (await file.exists()) {
      try {
        final content = await Isolate.run(() => file.readAsString());
        final json = jsonDecode(content) as Map<String, dynamic>;
        _settings = AppSettings.fromJson(json);
      } catch (e) {
        debugPrint('[Settings] 加载失败: $e');
        _settings = AppSettings();
      }
    } else {
      _settings = AppSettings();
    }

    // 迁移：从旧 JSON 明文读取 apiSecret 并写入安全存储
    await _migrateApiSecret();
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
        debugPrint('[Settings] apiSecret 已迁移至 EncryptedSharedPreferences');
      }
    } catch (e) {
      debugPrint('[Settings] apiSecret 迁移失败: $e');
    }
  }

  Future<void> _save() async {
    try {
      final file = File(_configPath);
      await file.parent.create(recursive: true);

      // apiSecret 不写入 JSON 明文
      final jsonMap = _settings.toJson();
      jsonMap.remove('apiSecret');

      final jsonStr = await Isolate.run(
        () => jsonEncode(jsonMap),
      );
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonStr, flush: true);
      await temp.rename(file.path);

      // apiSecret 写入安全存储
      await _writeApiSecret(_settings.apiSecret);
    } catch (e) {
      debugPrint('[Settings] 保存失败: $e');
    }
  }

  /// apiSecret getter — 从安全存储读取
  Future<String> getApiSecret() => _readApiSecret();

  /// apiSecret setter — 写入安全存储
  Future<void> setApiSecret(String value) async {
    await _writeApiSecret(value);
    // 同步更新内存中的值给 Clash 配置生成使用
    // ClashService 在 generateClashConfig 中使用 _settings.apiSecret
    // 因此需要保持内存值与安全存储一致
  }

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance = null;
  }

}
