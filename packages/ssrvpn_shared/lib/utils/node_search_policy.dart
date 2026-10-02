import '../models/proxy_node.dart';

/// Literal, case-insensitive fuzzy matching; no user-supplied regex execution.
class NodeSearchPolicy {
  static const maxQueryLength = 128;
  static bool matches(ProxyNode node, String query) {
    final terms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty);
    final text = '${node.name} ${node.group} ${node.type}'.toLowerCase();
    return terms.every(text.contains);
  }
}
