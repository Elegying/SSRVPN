import 'package:ssrvpn_shared/ssrvpn_shared.dart';

bool isAndroidNodeLatencyResultCurrent({
  required int operationGeneration,
  required int currentGeneration,
  required int operationSubscriptionRevision,
  required int currentSubscriptionRevision,
  required String nodeName,
  required String server,
  required int port,
  required Iterable<ProxyNode> currentNodes,
}) {
  if (operationGeneration != currentGeneration ||
      operationSubscriptionRevision != currentSubscriptionRevision) {
    return false;
  }
  return currentNodes.any(
    (node) =>
        node.name == nodeName && node.server == server && node.port == port,
  );
}
