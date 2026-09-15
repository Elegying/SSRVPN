import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:yaml/yaml.dart';

/// Freezes exactly the provider files referenced by the hashed configuration.
/// The privileged launcher verifies each copy before it starts the TUN runner.
Future<String> buildTunRuleStagingScript(
  List<int> configBytes,
  String dataDir,
) async {
  final dynamic config;
  try {
    config = loadYaml(utf8.decode(configBytes));
  } catch (_) {
    throw const FormatException('TUN_RULE_FILES: 无法读取分流规则配置');
  }
  final providers = config is Map ? config['rule-providers'] : null;
  if (providers == null) return '';
  if (providers is! Map) {
    throw const FormatException('TUN_RULE_FILES: 分流规则配置无效');
  }
  final script = StringBuffer();
  final copied = <String>{};
  for (final entry in providers.entries) {
    final provider = entry.value;
    if (provider is Map && provider['type'] == 'inline') continue;
    final path = provider is Map ? provider['path'] : null;
    final relative =
        path is String && path.startsWith('./') ? path.substring(2) : path;
    if (relative is! String ||
        !relative.startsWith('providers/') ||
        relative.split('/').any((part) =>
            part == '.' ||
            part == '..' ||
            !RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(part))) {
      throw const FormatException('TUN_RULE_FILES: 分流规则文件路径无效');
    }
    if (!copied.add(relative)) continue;
    var source = dataDir;
    final components = relative.split('/');
    for (var i = 0; i < components.length; i++) {
      source = '$source/${components[i]}';
      final expected = i == components.length - 1
          ? FileSystemEntityType.file
          : FileSystemEntityType.directory;
      if (await FileSystemEntity.type(source, followLinks: false) != expected) {
        throw FormatException('TUN_RULE_FILES: 分流规则文件缺失或不可用：$relative');
      }
      // Recheck the same path after authorization, before root reads it.
      script.writeln('[[ ! -L ${_quote(source)} ]] || exit 74');
    }
    final List<int> bytes;
    try {
      bytes = await File(source).readAsBytes();
    } on FileSystemException {
      throw FormatException('TUN_RULE_FILES: 无法读取分流规则文件：$relative');
    }
    if (bytes.isEmpty) {
      throw FormatException('TUN_RULE_FILES: 分流规则文件为空：$relative');
    }
    final destination = '"\$stage"/${_quote(relative)}';
    final parent = relative.substring(0, relative.lastIndexOf('/'));
    script
      ..writeln('/bin/mkdir -p "\$stage"/${_quote(parent)}')
      ..writeln('/bin/cp ${_quote(source)} $destination')
      ..writeln('/bin/chmod 600 $destination')
      ..writeln('check_hash $destination ${crypto.sha256.convert(bytes)}');
  }
  return script.toString();
}

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
