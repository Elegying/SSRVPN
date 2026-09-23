import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ssrvpn_shared/controllers/home_latency_controller.dart';
import 'package:ssrvpn_shared/services/node_latency_cache.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:ssrvpn_shared/services/subscription_service_base.dart';
import 'package:ssrvpn_shared/utils/node_display_policy.dart';
import 'package:test/test.dart';

const _yaml = '''
proxies:
  - {name: First, type: ss, server: one.example, port: 443, cipher: aes-128-gcm, password: secret-one}
  - {name: Second, type: ss, server: two.example, port: 443, cipher: aes-128-gcm, password: secret-two}
  - {name: Unknown, type: ss, server: three.example, port: 443, cipher: aes-128-gcm, password: secret-three}
''';

void main() {
  late Directory directory;
  late _Service service;
  late HomeLatencyController controller;
  final testedAt = DateTime.utc(2026, 9, 23, 10);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ssrvpn-latency-');
    service = _Service();
    await service.init(directory.path);
    await service.setRawYaml(_yaml);
    controller = HomeLatencyController()
      ..onResultsApplied =
          (nodes) => unawaited(service.saveLatencyResults(nodes));
  });
  tearDown(() async {
    await service.flushLatencyResults();
    service.dispose();
    await directory.delete(recursive: true);
  });

  Future<_Service> restart() async {
    await service.flushLatencyResults();
    final reopened = _Service();
    addTearDown(reopened.dispose);
    await reopened.init(directory.path);
    return reopened;
  }

  test('a fresh service restores the exact last result and test time',
      () async {
    final nodes = service.allNodes;
    controller.applyNow(nodes, 'First', 42, testedAt: testedAt);
    final batch = controller.beginBatch();
    controller.queueForBatch(batch, 'Second', 65535);
    controller.finishBatch(batch, nodes, testedAt: testedAt);

    final reopened = await restart();
    expect(reopened.allNodes.map((node) => node.latency), [42, 65535, null]);
    expect(reopened.allNodes.first.lastLatencyTest, testedAt);
    expect(reopened.allNodes.last.lastLatencyTest, isNull);
    expect(reopened.revision, 0);
    expect(reopened.rawYaml, service.rawYaml);
    final saved = await File('${directory.path}/${NodeLatencyCache.fileName}')
        .readAsString();
    for (final sensitive in ['First', 'example', 'secret-one', 'password']) {
      expect(saved, isNot(contains(sensitive)));
    }
    expect(reopened.rawYaml, isNot(contains('lastLatencyTest')));
  });

  test('completed progress survives cancellation and rejects late callbacks',
      () async {
    final batch = controller.beginBatch();
    controller.queueForBatch(batch, 'First', 42);
    controller.flushBatchTo(batch, service.allNodes, testedAt: testedAt);
    controller.queueForBatch(batch, 'Second', 77);
    controller.cancelBatch(batch);
    expect(controller.queueForBatch(batch, 'First', 900), isFalse);
    expect(controller.finishBatch(batch, service.allNodes), isFalse);
    final reopened = await restart();
    expect(reopened.allNodes.map((node) => node.latency), [42, null, null]);
  });

  test('new measurements replace both success and failure after restart',
      () async {
    controller.applyNow(service.allNodes, 'First', 42, testedAt: testedAt);
    controller.applyNow(service.allNodes, 'First', -1,
        testedAt: testedAt.add(const Duration(seconds: 1)));
    controller.applyNow(service.allNodes, 'Second', 65535, testedAt: testedAt);
    controller.applyNow(service.allNodes, 'Second', 68,
        testedAt: testedAt.add(const Duration(seconds: 2)));
    final reopened = await restart();
    expect(reopened.allNodes.map((node) => node.latency), [-1, 68, null]);
  });

  test('refresh retains unchanged nodes but not a replaced same-name endpoint',
      () async {
    final oldNodes = service.allNodes;
    controller.applyNow(oldNodes, 'First', 42, testedAt: testedAt);
    controller.applyNow(oldNodes, 'Second', 68, testedAt: testedAt);
    await service.setRawYaml(_yaml.replaceFirst('one.example', 'new.example'));
    expect(service.allNodes.map((node) => node.latency), [null, 68, null]);
    // Simulate a late result attempting to persist the detached old snapshot.
    controller.applyNow(oldNodes, 'First', 900,
        testedAt: testedAt.add(const Duration(seconds: 3)));
    final reopened = await restart();
    expect(reopened.allNodes.map((node) => node.latency), [null, 68, null]);
    await reopened.setRawYaml(_yaml);
    expect(reopened.allNodes.first.latency, 42);
  });

  test('shared endpoints retain each node result without cross-contamination',
      () async {
    await service.setRawYaml(_yaml.replaceFirst('two.example', 'one.example'));
    controller.applyNow(service.allNodes, 'First', 42, testedAt: testedAt);
    controller.applyNow(service.allNodes, 'Second', 68, testedAt: testedAt);
    final reopened = await restart();
    expect(reopened.allNodes.map((node) => node.latency), [42, 68, null]);
  });

  test('a port change discards only that node history', () async {
    controller.applyNow(service.allNodes, 'First', 42, testedAt: testedAt);
    controller.applyNow(service.allNodes, 'Second', 68, testedAt: testedAt);
    await service.setRawYaml(_yaml.replaceFirst('port: 443', 'port: 8443'));
    final reopened = await restart();
    expect(reopened.allNodes.map((node) => node.latency), [null, 68, null]);
  });

  test('a probe completed during publication is visible in the committed nodes',
      () async {
    final oldNodes = service.allNodes;
    service.afterSnapshotStaged = () {
      controller.applyNow(oldNodes, 'First', 42, testedAt: testedAt);
    };
    await service.setRawYaml(_yaml.replaceFirst('two.example', 'new.example'));
    expect(identical(service.allNodes.first, oldNodes.first), isFalse);
    expect(service.allNodes.first.latency, 42);
    final reopened = await restart();
    expect(reopened.allNodes.map((node) => node.latency), [42, null, null]);
  });

  test('all native failure categories survive restart with their original text',
      () async {
    for (var code = NodeDisplayPolicy.otherVpnActive;
        code <= NodeDisplayPolicy.probeTimedOut;
        code++) {
      controller.applyNow(service.allNodes, 'First', code, testedAt: testedAt);
      final reopened = await restart();
      expect(reopened.allNodes.first.latency, code);
      expect(reopened.allNodes.first.latencyText,
          NodeDisplayPolicy.latencyText(code));
    }
  });

  test('a failed write preserves the previous disk result and allows retry',
      () async {
    controller.applyNow(service.allNodes, 'First', 42, testedAt: testedAt);
    await service.flushLatencyResults();
    service.failLatencyWrites = true;
    controller.applyNow(service.allNodes, 'First', 900,
        testedAt: testedAt.add(const Duration(seconds: 1)));
    final afterFailure = await restart();
    expect(afterFailure.allNodes.first.latency, 42);
    expect(service.allNodes.first.latency, 900);
    service.failLatencyWrites = false;
    controller.applyNow(service.allNodes, 'First', 55,
        testedAt: testedAt.add(const Duration(seconds: 2)));
    final afterRetry = await restart();
    expect(afterRetry.allNodes.first.latency, 55);
  });

  for (final contents in [
    '{broken',
    jsonEncode({'version': 99, 'entries': <String, Object?>{}}),
    ' ' * (2 * 1024 * 1024 + 1),
  ]) {
    test(
        'invalid or oversized optional history does not block startup '
        '(${contents.length} bytes)', () async {
      await File('${directory.path}/${NodeLatencyCache.fileName}')
          .writeAsString(contents);
      final reopened = await restart();
      expect(reopened.allNodes, hasLength(3));
      expect(reopened.allNodes.every((node) => node.latency == null), isTrue);
    });
  }

  test('invalid cache entries are ignored individually', () async {
    final nodes = service.allNodes;
    await File('${directory.path}/${NodeLatencyCache.fileName}')
        .writeAsString(jsonEncode({
      'version': 1,
      'entries': {
        NodeLatencyCache.endpointKey(nodes[0]): {
          'latency': 42,
          'testedAt': testedAt.toIso8601String(),
        },
        NodeLatencyCache.endpointKey(nodes[1]): {
          'latency': '68',
          'testedAt': testedAt.toIso8601String(),
        },
        NodeLatencyCache.endpointKey(nodes[2]): {
          'latency': -9,
          'testedAt': 'invalid',
        },
      },
    }));
    final reopened = await restart();
    expect(reopened.allNodes.map((node) => node.latency), [42, null, null]);
  });
}

class _Service extends SubscriptionServiceBase {
  bool failLatencyWrites = false;
  void Function()? afterSnapshotStaged;

  @override
  void notifyListeners() {
    final callback = afterSnapshotStaged;
    afterSnapshotStaged = null;
    callback?.call();
    super.notifyListeners();
  }

  @override
  Future<void> writeStringAtomically(File file, String content) {
    if (failLatencyWrites && file.path.endsWith(NodeLatencyCache.fileName)) {
      throw const FileSystemException('Synthetic write failure');
    }
    return super.writeStringAtomically(file, content);
  }

  @override
  Future<String?> fetchSubscription(String url,
          {int maxRetries = 3, SubscriptionRefreshControl? control}) async =>
      _yaml;
}
