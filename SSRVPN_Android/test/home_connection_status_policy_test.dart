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
      errorMessage: '连接已中断，请重新连接',
      selectedNode: remembered,
      nodes: [remembered, nativeSelected],
      runtimeSelectedNodeName: nativeSelected.name,
    );
    final recovered = transitionAndroidHomeConnectionStatus(
      running: true,
      connecting: stopped.connecting,
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
      errorMessage: null,
      selectedNode: null,
      nodes: [remembered],
      runtimeSelectedNodeName: nativeSelected.name,
    );

    expect(transition.connected, isTrue);
    expect(transition.connecting, isTrue);
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
}
