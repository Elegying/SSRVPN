import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'bounded_yaml.dart';

/// Uses the parsed root key and source span, retaining quotes where possible.
/// Nested keys, comments and CRLF therefore have the same meaning everywhere.
String extractTopLevelYamlSection(String source, String sectionName) {
  try {
    final root = BoundedYaml.loadNode(source);
    if (root is! YamlMap) return '';
    final node = root.nodes[sectionName];
    if (node == null || node.value == null) return '';
    if (_containsBlockScalar(node)) {
      // Joining sections can add/remove newlines and change |+ / >+ values.
      // Encode those values explicitly rather than changing their content.
      return '  ${jsonEncode(node.value)}';
    }
    final text = '${' ' * node.span.start.column}${node.span.text}';
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    final meaningful = lines.where((line) => line.trim().isNotEmpty).toList();
    if (meaningful.isEmpty) return '';
    final indent = meaningful
        .map((line) => line.length - line.trimLeft().length)
        .reduce((a, b) => a < b ? a : b);
    return lines
        .map((line) => line.trim().isEmpty ? '' : '  ${line.substring(indent)}')
        .join('\n');
  } on FormatException {
    return '';
  } on JsonUnsupportedObjectError {
    return '';
  }
}

bool _containsBlockScalar(YamlNode node) => switch (node) {
      YamlScalar() =>
        node.style == ScalarStyle.LITERAL || node.style == ScalarStyle.FOLDED,
      YamlList() => node.nodes.any(_containsBlockScalar),
      YamlMap() => node.nodes.values.any(_containsBlockScalar),
      _ => false,
    };
