import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/screens/home_connection_status_policy.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  final remembered = ProxyNode(
    name: '新加坡节点',
    type: 'ss',
    server: 'sg.example.com',
    port: 443,
    latency: 80,
  );

  final nativeSelected = ProxyNode(
    name: '日本节点',
    type: 'ss',
    server: 'jp.example.com',
    port: 443,
    latency: 60,
  );

  test('native recovery clears interruption UI and restores the node', () {
    final stopped = transitionAndroidHomeConnectionStatus(
      running: false,
      connecting: false,
      connectionDesired: false,
      errorMessage: '连接已中断，请重新连接',
      selectedNode: remembered,
      nodes: [remembered, nativeSelected],
      runtimeSelectedNodeName: nativeSelected.name,
    );
    final recovered = transitionAndroidHomeConnectionStatus(
      running: true,
      connecting: stopped.connecting,
      connectionDesired: false,
      errorMessage: stopped.errorMessage,
      selectedNode: stopped.selectedNode,
      nodes: [remembered, nativeSelected],
      runtimeSelectedNodeName: nativeSelected.name,
    );

    expect(recovered.connected, isTrue);
    expect(recovered.connecting, isFalse);
    expect(recovered.errorMessage, isNull);
    expect(recovered.selectedNode, same(nativeSelected));
  });

  test('ordinary connect remains owned by its initiating continuation', () {
    final transition = transitionAndroidHomeConnectionStatus(
      running: true,
      connecting: true,
      connectionDesired: true,
      errorMessage: null,
      selectedNode: null,
      nodes: [remembered],
      runtimeSelectedNodeName: nativeSelected.name,
    );

    expect(transition.connected, isTrue);
    expect(transition.connecting, isTrue);
    expect(transition.selectedNode, isNull);
  });

  test('automatic reload preserves its busy state while stop is reported', () {
    final transition = transitionAndroidHomeConnectionStatus(
      running: false,
      connecting: true,
      connectionDesired: true,
      errorMessage: null,
      selectedNode: remembered,
      nodes: [remembered],
      runtimeSelectedNodeName: null,
    );

    expect(transition.connected, isFalse);
    expect(transition.connecting, isTrue);
    expect(transition.selectedNode, same(remembered));
  });

  test('manual cancellation clears busy state and the selected node', () {
    final transition = transitionAndroidHomeConnectionStatus(
      running: false,
      connecting: true,
      connectionDesired: false,
      errorMessage: null,
      selectedNode: remembered,
      nodes: [remembered],
      runtimeSelectedNodeName: null,
    );

    expect(transition.connected, isFalse);
    expect(transition.connecting, isFalse);
    expect(transition.selectedNode, isNull);
  });

  test('a running session refresh is handled even when UI stays connected', () {
    expect(
      shouldHandleAndroidHomeConnectionStatus(
        uiConnected: true,
        runtimeRunning: true,
      ),
      isTrue,
    );
    expect(
      shouldHandleAndroidHomeConnectionStatus(
        uiConnected: false,
        runtimeRunning: false,
      ),
      isFalse,
    );
  });

  test('failed latest switch resolves the node Mihomo actually uses', () {
    final resolved = resolveAndroidHomeNodeAfterFailedSwitch(
      nodes: [remembered, nativeSelected],
      runtimeSelectedNodeName: nativeSelected.name,
    );

    expect(resolved, same(nativeSelected));
  });

  test('disconnected node selection is remembered without a live switch', () {
    expect(
      resolveAndroidNodeSelectionIntent(
        isConnected: false,
        isConnecting: false,
      ),
      AndroidNodeSelectionIntent.rememberForNextConnection,
    );
    expect(
      resolveAndroidNodeSelectionIntent(
        isConnected: true,
        isConnecting: false,
      ),
      AndroidNodeSelectionIntent.switchLive,
    );
    expect(
      resolveAndroidNodeSelectionIntent(
        isConnected: false,
        isConnecting: true,
      ),
      AndroidNodeSelectionIntent.ignore,
    );
  });

  test('the pending UI selection wins when the next connection starts', () {
    expect(
      resolveAndroidPreferredNodeName(
        selectedNodeName: nativeSelected.name,
        rememberedNodeName: remembered.name,
      ),
      nativeSelected.name,
    );
    expect(
      resolveAndroidPreferredNodeName(
        selectedNodeName: null,
        rememberedNodeName: remembered.name,
      ),
      remembered.name,
    );
  });

  test('failed offline preference persistence rolls back only its own intent',
      () {
    expect(
      rollbackAndroidOfflineNodeSelection(
        previousNode: remembered,
        attemptedNode: nativeSelected,
        currentNode: nativeSelected,
      ),
      same(remembered),
    );

    final newerSelection = ProxyNode(
      name: 'Newer Selection',
      type: 'ss',
      server: 'newer.example.com',
      port: 443,
    );
    expect(
      rollbackAndroidOfflineNodeSelection(
        previousNode: remembered,
        attemptedNode: nativeSelected,
        currentNode: newerSelection,
      ),
      same(newerSelection),
    );
  });
}
