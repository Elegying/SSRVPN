import 'dart:io';

import 'package:ssrvpn_shared/services/subscription_service_base.dart';
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
  });
}

String _yamlFor(String name, {bool includeGroup = false}) => '''
proxies:
  - name: $name
    type: ss
    server: example.com
    port: 443
${includeGroup ? '''proxy-groups:
  - name: Existing Group
    type: select
    proxies:
      - $name
''' : ''}''';

class _FakeSubscriptionService extends SubscriptionServiceBase {
  String? response;
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
    required this.subscriptionName,
    required this.lastUpdate,
  });

  factory _ServiceSnapshot.capture(SubscriptionServiceBase service) {
    return _ServiceSnapshot(
      rawYaml: service.rawYaml,
      nodeNames: service.allNodes.map((node) => node.name).toList(),
      groupNames: service.allGroups.map((group) => group.name).toList(),
      revision: service.revision,
      subscriptionName: service.subscriptions.single.name,
      lastUpdate: service.subscriptions.single.lastUpdate,
    );
  }

  final String? rawYaml;
  final List<String> nodeNames;
  final List<String> groupNames;
  final int revision;
  final String subscriptionName;
  final DateTime? lastUpdate;

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
      service.subscriptions.single.name,
      subscriptionName,
      reason: 'subscription name changed',
    );
    expect(
      service.subscriptions.single.lastUpdate,
      lastUpdate,
      reason: 'lastUpdate changed',
    );
  }
}
