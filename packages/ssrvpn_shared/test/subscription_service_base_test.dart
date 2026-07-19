import 'dart:async';
import 'dart:io';

import 'package:ssrvpn_shared/services/subscription_service_base.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/utils/bounded_yaml.dart';
import 'package:test/test.dart';

void main() {
  test('rejects an oversized YAML cache before restoring it', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ssrvpn-oversized-yaml-cache-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = File('${directory.path}/subscription_cache.yaml');
    await cache.writeAsString('x' * (BoundedYaml.maxInputBytes + 1));

    final service = _FakeSubscriptionService();
    await service.init(directory.path);

    expect(service.rawYaml, isNull);
    expect(await cache.exists(), isFalse);
    expect(
      directory.listSync().map((entry) => entry.path),
      anyElement(predicate<String>((path) => path.contains('.bad-'))),
    );
  });

  group('SubscriptionServiceBase.refreshAllSubscriptions', () {
    late _FakeSubscriptionService service;
    late DateTime originalLastUpdate;
    late _ServiceSnapshot originalState;

    setUp(() async {
      service = _FakeSubscriptionService();
      final subscription = await service.addSubscription(
        'Primary',
        'https://feed.example.com/sub',
      );
      originalLastUpdate = DateTime.utc(2025, 1, 2, 3, 4, 5);
      subscription.lastUpdate = originalLastUpdate;
      await service.setRawYaml(_yamlFor('Old Node', includeGroup: true));
      originalState = _ServiceSnapshot.capture(service);
    });

    for (final entry in <String, String>{
      'empty response': '   ',
      'malformed YAML response': 'proxies:\n  - [unterminated',
      'response without runnable nodes': '''
proxies:
  - name: Disabled Node
    type: ss
    server: disabled.example.com
    port: 0
''',
    }.entries) {
      test('${entry.key} preserves the last valid state', () async {
        service.response = entry.value;

        await expectLater(
          service.refreshAllSubscriptions(),
          throwsA(anything),
        );

        originalState.expectUnchanged(service);
        expect(service.cachedYaml, originalState.rawYaml);
      });
    }

    test('cache failure preserves the last valid state', () async {
      service.response = _yamlFor('New Node');
      service.failCacheWrites = true;

      await expectLater(
        service.refreshAllSubscriptions(),
        throwsA(isA<FileSystemException>()),
      );

      originalState.expectUnchanged(service);
      expect(service.cachedYaml, originalState.rawYaml);
    });

    test('metadata save failure rolls back memory and cached YAML', () async {
      service.subscriptions.single.name = '';
      service.fetchedProfileName = 'Fetched Profile';
      originalState = _ServiceSnapshot.capture(service);
      service.response = _yamlFor('New Node');
      service.failMetadataWrites = true;
      var notifications = 0;
      service.addListener(() => notifications++);

      await expectLater(
        service.refreshAllSubscriptions(),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            'simulated metadata save failure',
          ),
        ),
      );

      originalState.expectUnchanged(service);
      expect(service.cachedYaml, originalState.rawYaml);
      expect(notifications, 0);
    });

    test('cache rollback failure preserves the metadata save error', () async {
      service.response = _yamlFor('New Node');
      service.failMetadataWrites = true;
      service.failOldYamlCacheWrites = true;

      await expectLater(
        service.refreshAllSubscriptions(),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            'simulated metadata save failure',
          ),
        ),
      );

      originalState.expectUnchanged(service);
      expect(service.cachedYaml, contains('New Node'));
    });

    test('successful refresh commits one consistent state', () async {
      service.response = _yamlFor('New Node');
      final oldRevision = service.revision;
      final observedStates = <_ServiceSnapshot>[];
      service.addListener(
        () => observedStates.add(_ServiceSnapshot.capture(service)),
      );

      final refreshedYaml = await service.refreshAllSubscriptions();

      expect(observedStates, hasLength(1));
      expect(observedStates.single.rawYaml, service.rawYaml);
      expect(observedStates.single.nodeNames, ['New Node']);
      expect(observedStates.single.groupNames, isEmpty);
      expect(refreshedYaml, service.rawYaml);
      expect(service.cachedYaml, service.rawYaml);
      expect(service.revision, oldRevision + 1);
      expect(service.allNodes.map((node) => node.name), ['New Node']);
      expect(service.allGroups, isEmpty);
      expect(
        service.subscriptions.single.lastUpdate,
        isNot(originalLastUpdate),
      );
    });

    test('large merge and parse yields the UI event queue before caching',
        () async {
      service.response = _largeYaml(3000);
      var heartbeat = false;
      service.cacheProbe = () => heartbeat;
      Timer.run(() => heartbeat = true);

      await service.refreshAllSubscriptions();

      expect(service.response!.length,
          greaterThan(SubscriptionServiceBase.processingIsolateThreshold));
      expect(service.cacheProbeResult, isTrue);
      expect(service.allNodes, hasLength(3000));
    });

    test('partial fetch returns details and preserves the last valid state',
        () async {
      await service.addSubscription(
        'Backup',
        'https://backup.example.com/sub',
      );
      originalState = _ServiceSnapshot.capture(service);
      service.responses = {
        'https://feed.example.com/sub': _yamlFor('New Primary'),
        'https://backup.example.com/sub': Exception('temporary timeout'),
      };

      final result = await service.refreshAllSubscriptionsDetailed();

      expect(result.status, SubscriptionBatchRefreshStatus.partialSuccess);
      expect(result.yaml, originalState.rawYaml);
      expect(result.successfulSubscriptionNames, ['Primary']);
      expect(result.failures, hasLength(1));
      expect(result.failures.single.subscriptionName, 'Backup');
      expect(result.failures.single.message, contains('temporary timeout'));
      originalState.expectUnchanged(service);
      expect(service.cachedYaml, originalState.rawYaml);
    });

    test('legacy refresh API still throws on a partial fetch', () async {
      await service.addSubscription(
        'Backup',
        'https://backup.example.com/sub',
      );
      service.responses = {
        'https://feed.example.com/sub': _yamlFor('New Primary'),
        'https://backup.example.com/sub': Exception('temporary timeout'),
      };

      await expectLater(
        service.refreshAllSubscriptions(),
        throwsA(
          isA<SubscriptionPartialRefreshException>().having(
            (error) => error.outcome.failures.single.subscriptionName,
            'failed subscription',
            'Backup',
          ),
        ),
      );
    });

    test(
        'deleting one subscription rolls back when every remaining source fails',
        () async {
      final removed = service.subscriptions.single;
      await service.addSubscription(
        'Backup',
        'https://backup.example.com/sub',
      );
      originalState = _ServiceSnapshot.capture(service);
      service.responses = {
        'https://backup.example.com/sub': Exception('temporary timeout'),
      };

      await expectLater(
        service.removeSubscription(removed.id),
        throwsA(anything),
      );

      originalState.expectUnchanged(service);
      expect(service.cachedYaml, originalState.rawYaml);
    });

    test(
        'deleting one subscription rolls back when remaining refresh is partial',
        () async {
      final removed = service.subscriptions.single;
      await service.addSubscription(
        'Backup A',
        'https://backup-a.example.com/sub',
      );
      await service.addSubscription(
        'Backup B',
        'https://backup-b.example.com/sub',
      );
      originalState = _ServiceSnapshot.capture(service);
      service.responses = {
        'https://backup-a.example.com/sub': _yamlFor('Fresh Backup'),
        'https://backup-b.example.com/sub': Exception('temporary timeout'),
      };

      await expectLater(
        service.removeSubscription(removed.id),
        throwsA(isA<SubscriptionPartialRefreshException>()),
      );

      originalState.expectUnchanged(service);
      expect(service.cachedYaml, originalState.rawYaml);
    });

    test('concurrent refreshes commit in request order', () async {
      final firstResponse = Completer<String?>();
      service.queuedResponses = [
        firstResponse.future,
        Future<String?>.value(_yamlFor('Newest Node')),
      ];

      final first = service.refreshAllSubscriptions();
      final second = service.refreshAllSubscriptions();
      await Future<void>.delayed(Duration.zero);
      firstResponse.complete(_yamlFor('Older Node'));

      await Future.wait([first, second]);

      expect(service.allNodes.map((node) => node.name), ['Newest Node']);
    });

    test('queued refresh deadline starts at public invocation', () async {
      final firstResponse = Completer<String?>();
      service.queuedResponses = [firstResponse.future];

      final first = service.refreshAllSubscriptions();
      await Future<void>.delayed(Duration.zero);
      final second = service.refreshAllSubscriptionsDetailed(
        timeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        second.timeout(const Duration(seconds: 1)),
        throwsA(isA<SubscriptionRefreshDeadlineExceeded>()),
      );
      expect(service.fetchCalls, 1);

      firstResponse.complete(_yamlFor('First Node'));
      await first;
      await service.addSubscription('Queue drain', 'ss://drain');
      expect(service.fetchCalls, 1);
    });

    test('queued refresh cancellation completes before queue admission',
        () async {
      final firstResponse = Completer<String?>();
      service.queuedResponses = [firstResponse.future];
      final cancellation = SubscriptionRefreshCancellation();

      final first = service.refreshAllSubscriptions();
      await Future<void>.delayed(Duration.zero);
      final second = service.refreshAllSubscriptionsDetailed(
        cancellation: cancellation,
      );
      cancellation.cancel();

      await expectLater(
        second.timeout(const Duration(seconds: 1)),
        throwsA(isA<SubscriptionRefreshCancelled>()),
      );
      expect(service.fetchCalls, 1);

      firstResponse.complete(_yamlFor('First Node'));
      await first;
      await service.addSubscription('Queue drain', 'ss://drain');
      expect(service.fetchCalls, 1);
    });

    test('add waits for an in-flight refresh before changing subscriptions',
        () async {
      final fetchStarted = Completer<void>();
      final response = Completer<String?>();
      service
        ..fetchStarted = fetchStarted
        ..queuedResponses = [response.future];

      final refresh = service.refreshAllSubscriptions();
      await fetchStarted.future;
      var addCompleted = false;
      final add = service
          .addSubscription('Queued', 'https://queued.example.com/sub')
          .whenComplete(() => addCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(addCompleted, isFalse);
      expect(service.subscriptions.map((sub) => sub.name), ['Primary']);

      response.complete(_yamlFor('Refreshed Node'));
      await refresh;
      await add;

      expect(
        service.subscriptions.map((sub) => sub.name),
        ['Primary', 'Queued'],
      );
      expect(service.allNodes.map((node) => node.name), ['Refreshed Node']);
    });

    test('remove waits for an in-flight refresh and then refreshes survivors',
        () async {
      final removed = await service.addSubscription(
        'Backup',
        'https://backup.example.com/sub',
      );
      final fetchStarted = Completer<void>();
      final firstResponse = Completer<String?>();
      service
        ..fetchStarted = fetchStarted
        ..queuedResponses = [
          firstResponse.future,
          Future<String?>.value(_yamlFor('Backup During Refresh')),
          Future<String?>.value(_yamlFor('Survivor After Removal')),
        ];

      final refresh = service.refreshAllSubscriptions();
      await fetchStarted.future;
      var removeCompleted = false;
      final remove = service
          .removeSubscription(removed.id)
          .whenComplete(() => removeCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(removeCompleted, isFalse);
      expect(service.subscriptions, hasLength(2));

      firstResponse.complete(_yamlFor('Primary During Refresh'));
      await refresh;
      await remove;

      expect(service.subscriptions.map((sub) => sub.name), ['Primary']);
      expect(
        service.allNodes.map((node) => node.name),
        ['Survivor After Removal'],
      );
    });

    test('update waits for an in-flight refresh before replacing metadata',
        () async {
      final fetchStarted = Completer<void>();
      final response = Completer<String?>();
      service
        ..fetchStarted = fetchStarted
        ..queuedResponses = [response.future];

      final refresh = service.refreshAllSubscriptions();
      await fetchStarted.future;
      final original = service.subscriptions.single;
      var updateCompleted = false;
      final update = service
          .updateSubscription(
            Subscription(
              id: original.id,
              name: 'Updated after refresh',
              url: 'https://updated.example.com/sub',
            ),
          )
          .whenComplete(() => updateCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(updateCompleted, isFalse);
      expect(service.subscriptions.single.name, 'Primary');

      response.complete(_yamlFor('Refreshed Before Update'));
      await refresh;
      await update;

      expect(service.subscriptions.single.name, 'Updated after refresh');
      expect(
        service.allNodes.map((node) => node.name),
        ['Refreshed Before Update'],
      );
    });

    test('cancelling a batch preserves the last valid state', () async {
      final response = Completer<String?>();
      service.queuedResponses = [response.future];
      final cancellation = SubscriptionRefreshCancellation();

      final refresh = service.refreshAllSubscriptionsDetailed(
        cancellation: cancellation,
        timeout: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();

      await expectLater(
        refresh,
        throwsA(isA<SubscriptionRefreshCancelled>()),
      );
      originalState.expectUnchanged(service);
      response.complete(_yamlFor('Late Node'));
      await Future<void>.delayed(Duration.zero);
      originalState.expectUnchanged(service);
    });

    test('batch deadline preserves the last valid state', () async {
      service.queuedResponses = [Completer<String?>().future];

      await expectLater(
        service.refreshAllSubscriptionsDetailed(
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<SubscriptionRefreshDeadlineExceeded>()),
      );

      originalState.expectUnchanged(service);
    });

    test('cancellation after the cache commit point finishes consistently',
        () async {
      final cacheStarted = Completer<void>();
      final releaseCache = Completer<void>();
      service
        ..response = _yamlFor('Committed Node')
        ..cacheWriteStarted = cacheStarted
        ..cacheWriteRelease = releaseCache;
      final cancellation = SubscriptionRefreshCancellation();

      final refresh = service.refreshAllSubscriptionsDetailed(
        cancellation: cancellation,
      );
      await cacheStarted.future;
      cancellation.cancel();
      releaseCache.complete();

      final result = await refresh;
      expect(result.status, SubscriptionBatchRefreshStatus.success);
      expect(service.allNodes.map((node) => node.name), ['Committed Node']);
      expect(service.cachedYaml, service.rawYaml);
    });

    test('failed add does not leak an unsaved subscription into memory',
        () async {
      service.failMetadataWrites = true;

      await expectLater(
        service.addSubscription('Unsaved', 'https://unsaved.example/sub'),
        throwsA(isA<FileSystemException>()),
      );

      originalState.expectUnchanged(service);
    });

    test('failed update restores the previous subscription object', () async {
      final original = service.subscriptions.single;
      service.failMetadataWrites = true;

      await expectLater(
        service.updateSubscription(
          Subscription(
            id: original.id,
            name: 'Unsaved name',
            url: original.url,
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );

      originalState.expectUnchanged(service);
    });

    test('failed remove restores the removed subscription', () async {
      final id = service.subscriptions.single.id;
      service.failMetadataWrites = true;

      await expectLater(
        service.removeSubscription(id),
        throwsA(isA<FileSystemException>()),
      );

      originalState.expectUnchanged(service);
    });

    test('failed last-subscription cache clear rolls back the removal',
        () async {
      final id = service.subscriptions.single.id;
      service.failCacheClears = true;

      await expectLater(
        service.removeSubscription(id),
        throwsA(isA<FileSystemException>()),
      );

      originalState.expectUnchanged(service);
    });

    test('failed edited-node cache write preserves live node state', () async {
      service.failCacheWrites = true;

      await expectLater(
        service.updateNode('Old Node', {
          'name': 'Edited Node',
          'type': 'ss',
          'server': 'edited.example.com',
          'port': 443,
          'cipher': 'aes-256-gcm',
          'password': 'secret',
        }),
        throwsA(isA<FileSystemException>()),
      );

      originalState.expectUnchanged(service);
    });

    test('failed raw YAML cache write preserves live node state', () async {
      service.failCacheWrites = true;

      await expectLater(
        service.setRawYaml(_yamlFor('Unsaved Node')),
        throwsA(isA<FileSystemException>()),
      );

      originalState.expectUnchanged(service);
    });
  });
}

String _yamlFor(String name, {bool includeGroup = false}) => '''
proxies:
  - name: $name
    type: ss
    server: example.com
    port: 443
    cipher: aes-256-gcm
    password: secret
${includeGroup ? '''proxy-groups:
  - name: Existing Group
    type: select
    proxies:
      - $name
''' : ''}''';

String _largeYaml(int count) {
  final buffer = StringBuffer('proxies:\n');
  for (var index = 0; index < count; index++) {
    buffer
      ..writeln('  - name: Node $index')
      ..writeln('    type: ss')
      ..writeln('    server: node-$index.example.com')
      ..writeln('    port: 443')
      ..writeln('    cipher: aes-256-gcm')
      ..writeln('    password: secret-$index');
  }
  return buffer.toString();
}

class _FakeSubscriptionService extends SubscriptionServiceBase {
  String? response;
  Map<String, Object?>? responses;
  List<Future<String?>>? queuedResponses;
  String? cachedYaml;
  String? fetchedProfileName;
  bool failCacheWrites = false;
  bool failMetadataWrites = false;
  bool failOldYamlCacheWrites = false;
  bool failCacheClears = false;
  bool Function()? cacheProbe;
  bool? cacheProbeResult;
  Completer<void>? cacheWriteStarted;
  Completer<void>? cacheWriteRelease;
  Completer<void>? fetchStarted;
  int fetchCalls = 0;

  @override
  Future<String?> fetchSubscription(
    String url, {
    int maxRetries = 3,
    SubscriptionRefreshControl? control,
  }) async {
    fetchCalls++;
    final started = fetchStarted;
    if (started != null && !started.isCompleted) started.complete();
    final profileName = fetchedProfileName;
    if (profileName != null) {
      recordSubscriptionResponseHeaders(url, {'profile-title': profileName});
    }
    final responseByUrl = responses;
    if (responseByUrl != null && responseByUrl.containsKey(url)) {
      final value = responseByUrl[url];
      if (value is Exception) throw value;
      return value as String?;
    }
    final queue = queuedResponses;
    if (queue != null && queue.isNotEmpty) return await queue.removeAt(0);
    return response;
  }

  @override
  Future<void> cacheYaml(String yaml) async {
    if (failCacheWrites ||
        (failOldYamlCacheWrites && yaml.contains('Old Node'))) {
      throw const FileSystemException('simulated cache write failure');
    }
    if (yaml.contains('Committed Node')) {
      final started = cacheWriteStarted;
      if (started != null && !started.isCompleted) started.complete();
      await cacheWriteRelease?.future;
    }
    final probe = cacheProbe;
    if (probe != null) cacheProbeResult = probe();
    cachedYaml = yaml;
  }

  @override
  Future<void> clearCachedNodes() async {
    if (failCacheClears) {
      throw const FileSystemException('simulated cache clear failure');
    }
    await super.clearCachedNodes();
  }

  @override
  Future<void> saveToDisk() async {
    if (failMetadataWrites) {
      throw const FileSystemException('simulated metadata save failure');
    }
  }
}

class _ServiceSnapshot {
  const _ServiceSnapshot({
    required this.rawYaml,
    required this.nodeNames,
    required this.groupNames,
    required this.revision,
    required this.subscriptionNames,
    required this.lastUpdates,
  });

  factory _ServiceSnapshot.capture(SubscriptionServiceBase service) {
    return _ServiceSnapshot(
      rawYaml: service.rawYaml,
      nodeNames: service.allNodes.map((node) => node.name).toList(),
      groupNames: service.allGroups.map((group) => group.name).toList(),
      revision: service.revision,
      subscriptionNames: service.subscriptions.map((sub) => sub.name).toList(),
      lastUpdates: service.subscriptions.map((sub) => sub.lastUpdate).toList(),
    );
  }

  final String? rawYaml;
  final List<String> nodeNames;
  final List<String> groupNames;
  final int revision;
  final List<String> subscriptionNames;
  final List<DateTime?> lastUpdates;

  void expectUnchanged(SubscriptionServiceBase service) {
    expect(service.rawYaml, rawYaml, reason: 'raw YAML changed');
    expect(
      service.allNodes.map((node) => node.name),
      nodeNames,
      reason: 'parsed nodes changed',
    );
    expect(
      service.allGroups.map((group) => group.name),
      groupNames,
      reason: 'parsed groups changed',
    );
    expect(service.revision, revision, reason: 'revision changed');
    expect(
      service.subscriptions.map((sub) => sub.name),
      subscriptionNames,
      reason: 'subscription names changed',
    );
    expect(
      service.subscriptions.map((sub) => sub.lastUpdate),
      lastUpdates,
      reason: 'lastUpdate values changed',
    );
  }
}
