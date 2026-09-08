import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/physical_tcp_latency.dart';

class _Probe with PhysicalTcpLatency {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final probe = _Probe();
  tearDown(() =>
      messenger.setMockMethodCallHandler(PhysicalTcpLatency.channel, null));
  test('unresolved host is passed to native physical network DNS', () async {
    messenger.setMockMethodCallHandler(PhysicalTcpLatency.channel,
        (call) async {
      expect(call.method, 'probe');
      expect(call.arguments,
          {'server': 'relay.example', 'port': 443, 'timeoutMs': 1200});
      return 180;
    });
    expect(await probe.testLatency('relay.example', 443, timeoutMs: 1200), 180);
  });
  test('missing binding cannot fall back to a reachable unbound socket',
      () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var accepted = 0;
    listener.listen((socket) {
      accepted++;
      socket.destroy();
    });
    addTearDown(listener.close);
    expect(await probe.testLatency('127.0.0.1', listener.port), -1);
    expect(accepted, 0);
  });
  test('invalid native values and native errors fail closed', () async {
    for (final value in <int?>[null, -1, 0, 5001]) {
      messenger.setMockMethodCallHandler(
          PhysicalTcpLatency.channel, (_) async => value);
      expect(await probe.testLatency('relay.example', 443), -1);
    }
    messenger.setMockMethodCallHandler(PhysicalTcpLatency.channel, (_) async {
      throw PlatformException(code: 'no_physical_network');
    });
    expect(await probe.testLatency('relay.example', 443), -1);
  });
  test('invalid requests never reach native channel', () async {
    messenger.setMockMethodCallHandler(PhysicalTcpLatency.channel, (_) async {
      fail('invalid probe dispatched');
    });
    expect(await probe.testLatency('bad host', 443), -1);
    expect(await probe.testLatency('relay.example', 0), -1);
    expect(await probe.testLatency('relay.example', 65536), -1);
    expect(await probe.testLatency('relay.example', 443, timeoutMs: 0), -1);
  });
  testWidgets('stalled native reply has a bounded deadline', (tester) async {
    final reply = Completer<int>();
    messenger.setMockMethodCallHandler(
        PhysicalTcpLatency.channel, (_) => reply.future);
    final pending = probe.testLatency('relay.example', 443, timeoutMs: 50);
    await tester.pump(const Duration(milliseconds: 301));
    expect(await pending, -1);
    reply.complete(1);
    await tester.pump();
  });
}
