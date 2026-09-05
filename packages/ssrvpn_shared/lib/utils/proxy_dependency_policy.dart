import 'dart:collection';

import 'proxy_node_usage_policy.dart';
import 'runtime_config_name_policy.dart';

/// Resolves references within one source before names enter the merged namespace.
class ProxyDependencyPolicy {
  const ProxyDependencyPolicy._();

  static String? reference(Map<Object?, Object?> proxy) {
    final value = proxy['dialer-proxy'];
    if (value == null) return null;
    if (value is! String) {
      throw const FormatException('链式代理入口必须是节点名称');
    }
    final name = RuntimeConfigNamePolicy.canonicalName(value);
    if (value.isNotEmpty && name.isEmpty) {
      throw const FormatException('链式代理入口名称不能为空白或控制字符');
    }
    return name.isEmpty ? null : name;
  }

  /// Dependency-first order, with identity-preserving edges. Walking rather
  /// than recursing keeps long, bounded subscriptions off the call stack.
  static List<(T, T?)> resolve<T extends Map<Object?, Object?>>(
      Iterable<T> proxies) {
    final runnable = proxies.where(ProxyNodeUsagePolicy.isRunnableProxyMap);
    final byName = <String, List<T>>{};
    for (final proxy in runnable) {
      final name = RuntimeConfigNamePolicy.canonicalName(proxy['name']);
      byName.putIfAbsent(name, () => []).add(proxy);
    }
    final edges = HashMap<T, T?>.identity();
    for (final proxy in runnable) {
      final name = reference(proxy);
      if (name == null) {
        edges[proxy] = null;
        continue;
      }
      final targets = byName[name];
      if (targets == null &&
          RuntimeConfigNamePolicy.mihomoBuiltinPolicyNames.contains(name)) {
        edges[proxy] = null;
      } else if (targets == null || targets.length != 1) {
        throw FormatException('链式代理入口“$name”不存在、重复或不是可用节点');
      } else {
        edges[proxy] = targets.single;
      }
    }
    final result = <(T, T?)>[];
    final done = HashSet<T>.identity();
    for (final root in runnable) {
      final path = <T>[];
      final visiting = HashSet<T>.identity();
      T? current = root;
      while (current != null && !done.contains(current)) {
        if (!visiting.add(current)) {
          throw const FormatException('链式代理存在循环引用');
        }
        path.add(current);
        current = edges[current];
      }
      for (final proxy in path.reversed) {
        done.add(proxy);
        result.add((proxy, edges[proxy]));
      }
    }
    return result;
  }
}
