import 'dart:async';
import 'dart:io';

import 'package:ssrvpn_shared/services/subscription_service_base.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:test/test.dart';

void main() {
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

class _FakeSubscriptionService extends SubscriptionServiceBase {
  String? response;
  Map<String, Object?>? responses;
  List<Future<String?>>? queuedResponses;
  String? cachedYaml;
  String? fetchedProfileName;
  bool failCacheWrites = false;
  bool failMetadataWrites = false;
  bool failOldYamlCacheWrites = false;

  @override
  Future<String?> fetchSubscription(String url, {int maxRetries = 3}) async {
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
    cachedYaml = yaml;
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
