import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/physical_tcp_latency.dart';
import 'package:ssrvpn_shared/utils/node_display_policy.dart';

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
    for (final value in <Object?>[null, '1', true, 1.5, -1, 0, 5001]) {
      messenger.setMockMethodCallHandler(
          PhysicalTcpLatency.channel, (_) async => value);
      expect(await probe.testLatency('relay.example', 443), -1);
    }
    messenger.setMockMethodCallHandler(PhysicalTcpLatency.channel, (_) async {
      throw PlatformException(code: 'no_physical_network');
    });
    expect(await probe.testLatency('relay.example', 443), -1);
  });
  test('native failure stages reach the UI without becoming timeouts',
      () async {
    for (final item in <int, String>{
      -10: '超时',
      -11: '解析失败',
      -12: '网络不可用',
      -13: '连接失败',
      -14: '测速繁忙',
      -15: '其他VPN占用',
    }.entries) {
      messenger.setMockMethodCallHandler(
          PhysicalTcpLatency.channel, (_) async => item.key);
      final value = await probe.testLatency('relay.example', 443);
      expect(value, item.key);
      expect(NodeDisplayPolicy.latencyText(value), item.value);
    }
    expect(NodeDisplayPolicy.latencyText(-1), '测速失败');
    expect(NodeDisplayPolicy.latencyText(null), '--');
  });
  test('overlapping batches share a bounded native probe queue', () async {
    var active = 0;
    var peak = 0;
    messenger.setMockMethodCallHandler(PhysicalTcpLatency.channel, (_) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
      return 25;
    });
    final probes =
        List.generate(30, (i) => _Probe().testLatency('node$i.example', 443));
    expect(await Future.wait(probes), everyElement(25));
    expect(peak, 8);
    expect(active, 0);
  });
  testWidgets('queue expiry is busy, releases its place and never probes',
      (tester) async {
    final replies = <Completer<int>>[];
    messenger.setMockMethodCallHandler(PhysicalTcpLatency.channel, (_) {
      final reply = Completer<int>();
      replies.add(reply);
      return reply.future;
    });
    final running =
        List.generate(8, (_) => probe.testLatency('relay.example', 443));
    await tester.pump();
    final queued = probe.testLatency('relay.example', 443, timeoutMs: 10);
    await tester.pump(const Duration(milliseconds: 11));
    expect(await queued, NodeDisplayPolicy.probeBusy);
    expect(replies.length, 8);
    for (final reply in replies) {
      reply.complete(1);
    }
    expect(await Future.wait(running), everyElement(1));
    messenger.setMockMethodCallHandler(
        PhysicalTcpLatency.channel, (_) async => 2);
    expect(await probe.testLatency('relay.example', 443), 2);
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
    expect(await pending, NodeDisplayPolicy.probeTimedOut);
    reply.complete(1);
    await tester.pump();
  });
}
