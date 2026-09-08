import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('single and batch probes use the physical native channel', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var calls = 0;
    messenger.setMockMethodCallHandler(PhysicalTcpLatency.channel,
        (call) async {
      calls++;
      expect(call.arguments['server'], 'relay.example');
      return 180;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(PhysicalTcpLatency.channel, null));
    final service = ClashService();
    addTearDown(service.dispose);
    final node = ProxyNode(
        name: 'Relay', type: 'ss', server: 'relay.example', port: 443);
    expect(await service.testNodeLatency(node), 180);
    final results = <int>[];
    await service
        .testAllLatencies([node], (_, latency) => results.add(latency));
    expect(results, [180]);
    expect(calls, 2);
  });
}
