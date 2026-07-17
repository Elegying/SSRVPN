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

  test('native recovery clears interruption UI and restores the node', () {
    final stopped = transitionAndroidHomeConnectionStatus(
      running: false,
      connecting: false,
      errorMessage: '连接已中断，请重新连接',
      selectedNode: remembered,
      nodes: [remembered],
      rememberedNodeName: remembered.name,
    );
    final recovered = transitionAndroidHomeConnectionStatus(
      running: true,
      connecting: stopped.connecting,
      errorMessage: stopped.errorMessage,
      selectedNode: stopped.selectedNode,
      nodes: [remembered],
      rememberedNodeName: remembered.name,
    );

    expect(recovered.connected, isTrue);
    expect(recovered.connecting, isFalse);
    expect(recovered.errorMessage, isNull);
    expect(recovered.selectedNode, same(remembered));
  });

  test('ordinary connect remains owned by its initiating continuation', () {
    final transition = transitionAndroidHomeConnectionStatus(
      running: true,
      connecting: true,
      errorMessage: null,
      selectedNode: null,
      nodes: [remembered],
      rememberedNodeName: remembered.name,
    );

    expect(transition.connected, isTrue);
    expect(transition.connecting, isTrue);
    expect(transition.selectedNode, isNull);
  });
}
