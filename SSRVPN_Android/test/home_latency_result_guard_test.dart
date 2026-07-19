import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/screens/home_latency_result_guard.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  final original = ProxyNode(
    name: 'Node A',
    type: 'ss',
    server: 'old.example.com',
    port: 443,
  );

  test('accepts only the current generation and exact node endpoint', () {
    expect(
      isAndroidNodeLatencyResultCurrent(
        operationGeneration: 4,
        currentGeneration: 4,
        operationSubscriptionRevision: 8,
        currentSubscriptionRevision: 8,
        nodeName: original.name,
        server: original.server,
        port: original.port,
        currentNodes: [original],
      ),
      isTrue,
    );
  });

  test('rejects an old result after the subscription endpoint changes', () {
    expect(
      isAndroidNodeLatencyResultCurrent(
        operationGeneration: 4,
        currentGeneration: 4,
        operationSubscriptionRevision: 8,
        currentSubscriptionRevision: 9,
        nodeName: original.name,
        server: original.server,
        port: original.port,
        currentNodes: [
          ProxyNode(
            name: 'Node A',
            type: 'ss',
            server: 'new.example.com',
            port: 8443,
          ),
        ],
      ),
      isFalse,
    );
  });

  test('rejects an earlier single-node test generation', () {
    expect(
      isAndroidNodeLatencyResultCurrent(
        operationGeneration: 3,
        currentGeneration: 4,
        operationSubscriptionRevision: 8,
        currentSubscriptionRevision: 8,
        nodeName: original.name,
        server: original.server,
        port: original.port,
        currentNodes: [original],
      ),
      isFalse,
    );
  });
}
