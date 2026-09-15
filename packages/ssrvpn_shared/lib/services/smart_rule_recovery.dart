import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../constants/app_constants.dart';
import '../utils/bounded_yaml.dart';
import 'smart_rule_bundle.dart';

/// Persists only rules, never subscription credentials or a complete VPN config.
/// A failed candidate is retired before restoring the last core-confirmed set.
class SmartRuleRecovery {
  SmartRuleRecovery(this.configDir, {Set<String>? fileNames})
      : fileNames = fileNames ??
            {
              ...AppConstants.smartRuleProviderFiles.values,
              if (Platform.isAndroid) ...SmartRuleBundle.androidFiles,
            };

  final String configDir;
  final Set<String> fileNames;
  File get _journal => File('$configDir/providers/rule-recovery.json');

  Future<Map<String, dynamic>> _read() async {
    try {
      return await _readValidated();
    } on FormatException {
      // A damaged journal is not evidence of a confirmed or rejected version.
      // The next successful core start can replace it atomically; until then,
      // the updater still requires a confirmed, fully verified snapshot.
      return {};
    } on TypeError {
      return {};
    }
  }

  Future<Map<String, dynamic>> _readValidated() async {
    if (!await _journal.exists()) return {};
    if (await _journal.length() > SmartRuleBundle.maxManifestBytes * 2) {
      throw const FormatException('规则恢复记录过大');
    }
    final value = jsonDecode(await _journal.readAsString());
    if (value is! Map<String, dynamic>) {
      throw const FormatException('规则恢复记录无效');
    }
    final good = value['confirmed'];
    if (good != null) {
      SmartRuleBundle.parseManifest(jsonEncode(good),
          expectedFileNames: fileNames);
    }
    final rejected = value['rejectedThrough'];
    if (rejected != null) {
      SmartRuleBundle.providerPathPrefix(rejected as String);
    }
    return value;
  }

  Future<void> _write(Map<String, dynamic> value) async {
    await _journal.parent.create(recursive: true);
    final temporary = File('${_journal.path}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(value), flush: true);
      await temporary.rename(_journal.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<bool> rejects(String version) async {
    final rejected = (await _read())['rejectedThrough'] as String?;
    return rejected != null &&
        !SmartRuleVersionDescriptor(version: version, manifestSha256: '')
            .isNewerThan(rejected);
  }

  Future<String?> repairRejectedSelection() async {
    final record = await _read();
    if (record['rejectedThrough'] == null || record['confirmed'] == null) {
      return null;
    }
    final goodText = jsonEncode(record['confirmed']);
    final good =
        SmartRuleBundle.parseManifest(goodText, expectedFileNames: fileNames);
    final active = await SmartRuleBundle.readInstalledManifest(configDir,
        expectedFileNames: fileNames);
    if (active?.version == good.version) return good.version;
    if (active != null && !await rejects(active.version)) return null;
    if (!await SmartRuleBundle.activateInstalledManifest(configDir, goodText,
        expectedFileNames: fileNames)) {
      throw const FormatException('上一份规则已损坏，不能恢复');
    }
    return good.version;
  }

  static String? configVersion(String config) {
    final document = BoundedYaml.load(config);
    final providers = document is Map ? document['rule-providers'] : null;
    if (providers is! Map) return null;
    String? version;
    for (final entry in AppConstants.smartRuleProviderFiles.entries) {
      final provider = providers[entry.key];
      final path = provider is Map ? provider['path'] : null;
      if (path is! String) return null;
      final match =
          RegExp(r'^\./providers/bundles/([^/]+)/([^/]+)$').firstMatch(path);
      if (match == null || match[2] != entry.value) return null;
      SmartRuleBundle.providerPathPrefix(match[1]!);
      version ??= match[1];
      if (version != match[1]) return null;
    }
    return version;
  }

  static Map<String, dynamic> _manifestJson(SmartRuleManifest manifest) => {
        'schemaVersion': 1,
        'version': manifest.version,
        'componentVersions': manifest.componentVersions,
        'files': [
          for (final entry in manifest.files.values)
            {
              'name': entry.name,
              'behavior': entry.behavior,
              'count': entry.count,
              'sha256': entry.sha256
            },
        ],
      };

  /// Only rule-loading diagnostics qualify; transport, permissions and generic
  /// startup failures must never reject a rule snapshot.
  static bool isRuleLoadFailure(String? message) {
    final text = message?.toLowerCase() ?? '';
    if (RegExp(
            r'permission denied|access is denied|operation not permitted|address already in use|eaddrinuse|cancelled|已取消|core_start_permission|core_start_port_conflict|core_start_tun|core_start_api_auth|core_start_timeout')
        .hasMatch(text)) {
      return false;
    }
    return text.contains('core_start_rules:') ||
        text.contains('分流规则尚未就绪') ||
        (text.contains('tun_rule_files:') &&
            (text.contains('分流规则文件缺失或不可用：') || text.contains('分流规则文件为空：'))) ||
        RegExp(r'(rule provider|rule-provider|rule set|rule-set|rules\[)[^\n]*(failed|error|invalid|not found)')
            .hasMatch(text) ||
        RegExp(r'(failed|error|invalid)[^\n]*(rule provider|rule-provider|rule set|rule-set|rules\[)')
            .hasMatch(text);
  }

  Future<bool> run({
    required String configPath,
    required Future<bool> Function() start,
    required Future<void> Function() stopFailedStart,
    required bool Function() isCurrent,
    required bool Function() isRunning,
    required String? Function() failureReason,
    required Future<void> Function(String version) selectVersion,
    required void Function(String message) log,
  }) async {
    final wasRunning = isRunning();
    SmartRuleManifest? candidate;
    String? version;
    try {
      final source = await File(configPath).readAsString();
      version = await _configVersionInBackground(source);
      final record = await _read();
      if (version != null &&
          (record['confirmed'] as Map?)?['version'] != version) {
        final text = await File(
                '$configDir/providers/${SmartRuleBundle.installedManifestFileName}')
            .readAsString();
        final active =
            SmartRuleBundle.parseManifest(text, expectedFileNames: fileNames);
        if (active.version == version) candidate = active;
      }
    } catch (_) {
      // The normal platform start reports missing/invalid configuration.
    }
    if (!isCurrent()) return false;
    final success = await start();
    if (!isCurrent()) return false;
    if (success) {
      if (candidate != null && !wasRunning) {
        try {
          final record = await _read();
          if (isCurrent()) {
            await _write({...record, 'confirmed': _manifestJson(candidate)});
          }
        } catch (_) {
          log('规则运行确认记录保存失败，当前连接保持；暂不启用新的远程规则');
        }
      }
      return isCurrent();
    }
    if (version == null || !isRuleLoadFailure(failureReason())) return false;
    try {
      final record = await _read();
      final goodText = jsonEncode(record['confirmed']);
      final good =
          SmartRuleBundle.parseManifest(goodText, expectedFileNames: fileNames);
      if (good.version == version || !isCurrent()) return false;
      // Retry only after platform cleanup has fully released core/TUN resources.
      await stopFailedStart();
      if (!isCurrent() || isRunning()) return false;
      final currentText = await File(configPath).readAsString();
      if (await _configVersionInBackground(currentText) != version ||
          !isCurrent()) {
        return false;
      }
      final rejected = record['rejectedThrough'] as String?;
      final highWater = rejected == null ||
              SmartRuleVersionDescriptor(version: version, manifestSha256: '')
                  .isNewerThan(rejected)
          ? version
          : rejected;
      await _write({...record, 'rejectedThrough': highWater});
      if (!isCurrent()) return false;
      final fallback = await _rewriteInBackground(currentText, good.version);
      if (!isCurrent()) return false;
      if (!await SmartRuleBundle.activateInstalledManifest(configDir, goodText,
          expectedFileNames: fileNames)) {
        return false;
      }
      if (!isCurrent()) return false;
      await selectVersion(good.version);
      if (!isCurrent()) return false;
      final file = File(configPath);
      final temporary = File('$configPath.rule-recovery.tmp');
      try {
        await temporary.writeAsString(fallback, flush: true);
        if (!isCurrent()) return false;
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      if (!isCurrent()) return false;
      log('新版规则未能加载，已恢复上一份可用规则 ${good.version}');
      // One retry only. Neither ordinary failures nor cancellation loop here.
      return await start() && isCurrent();
    } catch (_) {
      log('规则恢复未完成，保留恢复记录，等待下次连接');
      return false;
    }
  }

  Future<bool> get hasConfirmedVersion async {
    final confirmed = (await _read())['confirmed'];
    if (confirmed == null) return false;
    return SmartRuleBundle.verifyVersion(
        configDir,
        SmartRuleBundle.parseManifest(jsonEncode(confirmed),
            expectedFileNames: fileNames));
  }

  static Future<String?> _configVersionInBackground(String source) =>
      Isolate.run(() => configVersion(source));

  Future<String> _rewriteInBackground(String source, String version) =>
      Isolate.run(() => rewriteConfig(source, version));

  Future<String> rewriteConfig(String source, String version) async {
    // JSON is valid YAML. Round-tripping the map changes only provider paths
    // and Android application policy, never values inside node credentials.
    final document = jsonDecode(jsonEncode(BoundedYaml.load(source)))
        as Map<String, dynamic>;
    final providers = document['rule-providers'] as Map<String, dynamic>;
    for (final entry in AppConstants.smartRuleProviderFiles.entries) {
      (providers[entry.key] as Map<String, dynamic>)['path'] =
          '${SmartRuleBundle.providerPathPrefix(version)}/${entry.value}';
    }
    var header = '';
    if (fileNames.containsAll(SmartRuleBundle.androidFiles)) {
      final next = await SmartRuleBundle.androidRules(configDir, version);
      final rules = (document['rules'] as List).cast<String>().toList();
      // The rejected files may be unreadable. Application rules in generated
      // configs come exclusively from our lists; subscriptions supply nodes only.
      final previous =
          rules.where((rule) => rule.startsWith('PROCESS-NAME,')).toSet();
      var insertion = rules.indexWhere(previous.contains);
      if (insertion < 0) {
        insertion = rules.indexOf(AppConstants.rejectIpv6Rule) + 1;
      }
      rules.removeWhere(previous.contains);
      rules.insertAll(insertion.clamp(0, rules.length), next);
      document['rules'] = rules;
      final direct = next
          .where((rule) => rule.endsWith(',DIRECT'))
          .map((rule) => rule.split(',')[1]);
      header = '# ssrvpn-direct-apps: ${direct.join(',')}\n';
    }
    return '$header${jsonEncode(document)}\n';
  }
}
