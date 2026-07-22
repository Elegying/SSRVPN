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
  required bool uiConnecting,
  required bool uiNativeRecoveryActive,
  required bool runtimeRunning,
  required bool runtimeTransitioning,
}) =>
    runtimeRunning ||
    runtimeTransitioning ||
    uiConnecting ||
    uiNativeRecoveryActive ||
    uiConnected != runtimeRunning;

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
    required this.nativeRecoveryActive,
    required this.errorMessage,
    required this.selectedNode,
  });

  final bool connected;
  final bool connecting;
  final bool nativeRecoveryActive;
  final String? errorMessage;
  final ProxyNode? selectedNode;
}

AndroidHomeConnectionStatusTransition transitionAndroidHomeConnectionStatus({
  required bool running,
  required bool connecting,
  required bool connectionDesired,
  required bool nativeTransitioning,
  required bool nativeRecoveryActive,
  required String? errorMessage,
  required ProxyNode? selectedNode,
  required Iterable<ProxyNode> nodes,
  required String? runtimeSelectedNodeName,
}) {
  if (!running) {
    if (nativeTransitioning || (connecting && connectionDesired)) {
      return AndroidHomeConnectionStatusTransition(
        connected: false,
        connecting: true,
        nativeRecoveryActive: nativeTransitioning,
        errorMessage: errorMessage,
        selectedNode: selectedNode,
      );
    }
    return AndroidHomeConnectionStatusTransition(
      connected: false,
      connecting: false,
      nativeRecoveryActive: false,
      errorMessage: errorMessage,
      selectedNode: null,
    );
  }

  // During an ordinary connect, the initiating continuation still owns final
  // publication. A false -> true transition while no connect is pending is a
  // native recovery and must retire the stale interruption UI itself.
  if (nativeRecoveryActive) {
    return AndroidHomeConnectionStatusTransition(
      connected: true,
      connecting: false,
      nativeRecoveryActive: false,
      errorMessage: null,
      selectedNode: HomeNodeController.resolveRuntimeSelectedNodeFrom(
            nodes,
            runtimeSelectedNodeName,
          ) ??
          selectedNode,
    );
  }
  if (connecting) {
    return AndroidHomeConnectionStatusTransition(
      connected: true,
      connecting: true,
      nativeRecoveryActive: false,
      errorMessage: errorMessage,
      selectedNode: selectedNode,
    );
  }
  return AndroidHomeConnectionStatusTransition(
    connected: true,
    connecting: false,
    nativeRecoveryActive: false,
    errorMessage: null,
    selectedNode: HomeNodeController.resolveRuntimeSelectedNodeFrom(
          nodes,
          runtimeSelectedNodeName,
        ) ??
        selectedNode,
  );
}
