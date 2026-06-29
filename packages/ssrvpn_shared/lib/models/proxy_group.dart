import 'proxy_node.dart';

class ProxyGroup {
  ProxyGroup({
    required this.name,
    required this.type,
    required this.nodes,
    this.selectedNode,
  });

  final String name;
  final String type;
  final List<ProxyNode> nodes;
  final String? selectedNode;

  factory ProxyGroup.fromJson(Map<String, dynamic> json) {
    final rawNodes = json['nodes'];
    return ProxyGroup(
      name: json['name']?.toString() ?? 'Unknown',
      type: json['type']?.toString() ?? 'select',
      nodes: rawNodes is Iterable
          ? rawNodes
              .whereType<Map>()
              .map(
                (node) => ProxyNode.fromJson(
                  node.map((key, value) => MapEntry(key.toString(), value)),
                ),
              )
              .toList()
          : <ProxyNode>[],
      selectedNode: json['selectedNode']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        'nodes': nodes.map((node) => node.toJson()).toList(),
        'selectedNode': selectedNode,
      };
}
