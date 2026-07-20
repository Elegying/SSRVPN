import 'package:ssrvpn_shared/ssrvpn_shared.dart';

enum AndroidNodeSelectionIntent {
  ignore,
  rememberForNextConnection,
  switchLive,
}

AndroidNodeSelectionIntent resolveAndroidNodeSelectionIntent({
  required bool isConnected,
  required bool isConnecting,
}) {
  if (isConnecting) return AndroidNodeSelectionIntent.ignore;
  return isConnected
      ? AndroidNodeSelectionIntent.switchLive
      : AndroidNodeSelectionIntent.rememberForNextConnection;
}

String? resolveAndroidPreferredNodeName({
  required String? selectedNodeName,
  required String? rememberedNodeName,
}) =>
    selectedNodeName ?? rememberedNodeName;

ProxyNode? rollbackAndroidOfflineNodeSelection({
  required ProxyNode? previousNode,
  required ProxyNode attemptedNode,
  required ProxyNode? currentNode,
}) {
  return currentNode?.name == attemptedNode.name ? previousNode : currentNode;
}

bool shouldHandleAndroidHomeConnectionStatus({
  required bool uiConnected,
  required bool runtimeRunning,
}) =>
    runtimeRunning || uiConnected != runtimeRunning;

ProxyNode? resolveAndroidHomeNodeAfterFailedSwitch({
  required Iterable<ProxyNode> nodes,
  required String? runtimeSelectedNodeName,
}) =>
    HomeNodeController.resolveRuntimeSelectedNodeFrom(
      nodes,
      runtimeSelectedNodeName,
    );

class AndroidHomeConnectionStatusTransition {
  const AndroidHomeConnectionStatusTransition({
    required this.connected,
    required this.connecting,
    required this.errorMessage,
    required this.selectedNode,
  });

  final bool connected;
  final bool connecting;
  final String? errorMessage;
  final ProxyNode? selectedNode;
}

AndroidHomeConnectionStatusTransition transitionAndroidHomeConnectionStatus({
  required bool running,
  required bool connecting,
  required bool connectionDesired,
  required String? errorMessage,
  required ProxyNode? selectedNode,
  required Iterable<ProxyNode> nodes,
  required String? runtimeSelectedNodeName,
}) {
  if (!running) {
    if (connecting && connectionDesired) {
      return AndroidHomeConnectionStatusTransition(
        connected: false,
        connecting: true,
        errorMessage: errorMessage,
        selectedNode: selectedNode,
      );
    }
    return AndroidHomeConnectionStatusTransition(
      connected: false,
      connecting: false,
      errorMessage: errorMessage,
      selectedNode: null,
    );
  }

  // During an ordinary connect, the initiating continuation still owns final
  // publication. A false -> true transition while no connect is pending is a
  // native recovery and must retire the stale interruption UI itself.
  if (connecting) {
    return AndroidHomeConnectionStatusTransition(
      connected: true,
      connecting: true,
      errorMessage: errorMessage,
      selectedNode: selectedNode,
    );
  }
  return AndroidHomeConnectionStatusTransition(
    connected: true,
    connecting: false,
    errorMessage: null,
    selectedNode: HomeNodeController.resolveRuntimeSelectedNodeFrom(
          nodes,
          runtimeSelectedNodeName,
        ) ??
        selectedNode,
  );
}
