import 'dart:async';
import 'dart:io';

import 'package:ssrvpn_shared/services/subscription_service_base.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:ssrvpn_shared/services/subscription_processing.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/utils/bounded_yaml.dart';
import 'package:test/test.dart';

void main() {
  test('default-port proxies do not turn subscription URLs into node links',
      () {
    final service = _FakeSubscriptionService();
    addTearDown(service.dispose);
    for (final link in [
      'http://user:fixture@127.0.0.1:80',
      'https://user:fixture@[2001:db8::1]:443',
    ]) {
      expect(service.isSingleNodeLink(link), isTrue);
    }
    for (final link in [
      'https://feed.invalid',
      'https://feed.invalid:443',
      'https://feed.invalid:443/',
      'http://feed.invalid:80',
      'https://feed.invalid:443/subscription',
      'https://feed.invalid:443/?token=fixture',
      'http://feed.invalid:80/subscription',
      'https://user:fixture@feed.invalid:443/subscription',
    ]) {
      expect(service.isSingleNodeLink(link), isFalse);
    }
  });

  test('failed atomic subscription write removes only its temporary file',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('ssrvpn-failed-cache-write-');
    addTearDown(() => directory.delete(recursive: true));
    final occupied = Directory('${directory.path}/subscription_cache.yaml');
    await occupied.create();
    final retained = File('${occupied.path}/keep');
    await retained.writeAsString('existing data');
    final service = _FakeSubscriptionService();
    addTearDown(service.dispose);
    await expectLater(
        service.writeStringAtomically(File(occupied.path), _yamlFor('Node')),
        throwsA(isA<FileSystemException>()));
    expect(await retained.readAsString(), 'existing data');
    expect(directory.listSync().where((entry) => entry.path.contains('.tmp.')),
        isEmpty);
  });

  for (final name in ['subscriptions.json', 'subscription_cache.yaml']) {
    test('temporary read failure preserves $name and the last loaded nodes',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('ssrvpn-unreadable-cache-');
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/subscriptions.json').writeAsString(
          '[{"id":"saved","name":"Saved","url":"https://feed.example/sub"}]');
      final yaml = _yamlFor('Saved Node');
      await File('${directory.path}/subscription_cache.yaml')
          .writeAsString(yaml);
      final service = _FakeSubscriptionService();
      addTearDown(service.dispose);
      await service.init(directory.path);
      final file = File('${directory.path}/$name');
      expect((await Process.run('/bin/chmod', ['000', file.path])).exitCode, 0);
      addTearDown(() async {
        if (await file.exists()) {
          await Process.run('/bin/chmod', ['600', file.path]);
        }
      });
      try {
        await file.readAsString();
        markTestSkipped('This user can bypass file permissions');
        return;
      } on FileSystemException {
        // Exercise a real transient read error without changing user data.
      }

      await expectLater(
          service.loadFromDisk(), throwsA(isA<FileSystemException>()));
      expect(await file.exists(), isTrue);
      expect(service.subscriptions.single.id, 'saved');
      expect(service.allNodes.single.name, 'Saved Node');
      expect(service.rawYaml, yaml);
      expect(
          directory.listSync().where((entry) => entry.path.contains('.bad-')),
          isEmpty);
      expect((await Process.run('/bin/chmod', ['600', file.path])).exitCode, 0);
      await service.loadFromDisk();
      expect(service.subscriptions.single.id, 'saved');
      expect(service.allNodes.single.name, 'Saved Node');
    }, skip: Platform.isWindows);
  }

  for (final name in ['subscriptions.json', 'subscription_cache.yaml']) {
    test('invalid UTF-8 in $name is still quarantined as damaged data',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('ssrvpn-invalid-utf8-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/$name');
      await file.writeAsBytes([0xff, 0xfe, 0xff]);
      final service = _FakeSubscriptionService();
      addTearDown(service.dispose);
      await service.init(directory.path);
      expect(await file.exists(), isFalse);
      expect(
          directory.listSync().where((entry) => entry.path.contains('.bad-')),
          isNotEmpty);
      expect(service.allNodes, isEmpty);
      expect(service.subscriptions, isEmpty);
    });
  }

  test('large startup cache parsing yields while a processing worker is active',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('ssrvpn-large-load-');
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}/subscription_cache.yaml')
        .writeAsString(_largeYaml(3000));
    final service = _FakeSubscriptionService();
    addTearDown(service.dispose);
    SubscriptionProcessing.workerStartDelayForTesting =
        const Duration(milliseconds: 50);
    addTearDown(() =>
        SubscriptionProcessing.workerStartDelayForTesting = Duration.zero);
    var yieldedDuringProcessing = false;
    final heartbeat = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (SubscriptionProcessing.activeWorkerCount > 0) {
        yieldedDuringProcessing = true;
      }
    });
    addTearDown(heartbeat.cancel);

    await service.init(directory.path);

    expect(yieldedDuringProcessing, isTrue);
    expect(service.allNodes, hasLength(3000));
    expect(service.revision, 0);
    expect(SubscriptionProcessing.activeWorkerCount, 0);
  });

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

  test('startup preserves semantic failures but quarantines broken YAML',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('ssrvpn-cache-policy-');
    addTearDown(() => directory.delete(recursive: true));
    final cache = File('${directory.path}/subscription_cache.yaml');
    final invalidRuntime = '${_yamlFor('Node')}'
        '    dialer-proxy: Missing\n${'# padding\n' * 30000}';
    await cache.writeAsString(invalidRuntime);
    final service = _FakeSubscriptionService();
    addTearDown(service.dispose);
    await service.init(directory.path);
    expect(service.rawYaml, invalidRuntime);
    expect(service.allNodes, isEmpty);
    expect(await cache.readAsString(), invalidRuntime);
    expect(directory.listSync().where((file) => file.path.contains('.bad-')),
        isEmpty);

    await cache
        .writeAsString('proxies: [unterminated\n${'# padding\n' * 30000}');
    await service.loadFromDisk();
    expect(service.rawYaml, isNull);
    expect(await cache.exists(), isFalse);
    expect(directory.listSync().where((file) => file.path.contains('.bad-')),
        isNotEmpty);
  });

  test('cancelled startup processing keeps the valid cache file intact',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('ssrvpn-cache-cancel-');
    addTearDown(() => directory.delete(recursive: true));
    final service = _FakeSubscriptionService();
    addTearDown(service.dispose);
    await service.init(directory.path);
    final yaml = _largeYaml(3000);
    final cache = File('${directory.path}/subscription_cache.yaml');
    await cache.writeAsString(yaml);
    SubscriptionProcessing.workerStartDelayForTesting =
        const Duration(seconds: 5);
    addTearDown(() =>
        SubscriptionProcessing.workerStartDelayForTesting = Duration.zero);
    final cancellation = SubscriptionRefreshCancellation();
    final loading = service.loadFromDisk(
        control: SubscriptionRefreshControl(
            timeout: const Duration(seconds: 30), cancellation: cancellation));
    final expectation =
        expectLater(loading, throwsA(isA<SubscriptionRefreshCancelled>()));
    await _waitForProcessingWorkers(active: true);
    cancellation.cancel();
    await expectation;
    await _waitForProcessingWorkers(active: false);
    expect(await cache.readAsString(), yaml);
    expect(service.rawYaml, isNull);
    expect(service.allNodes, isEmpty);
    expect(directory.listSync().where((file) => file.path.contains('.bad-')),
        isEmpty);
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

    test('large cached source extraction yields before the next fetch',
        () async {
      await service.setRawYaml(_largeYaml(3000));
      service.response = _yamlFor('New Node');
      var heartbeat = false;
      service.fetchProbe = () => heartbeat;
      Timer.run(() => heartbeat = true);

      await service.refreshAllSubscriptions();

      expect(service.fetchProbeResult, isTrue);
      expect(service.allNodes.single.name, 'New Node');
    });

    test('cancelling cache extraction preserves state without beginning fetch',
        () async {
      await service.setRawYaml(_largeYaml(3000));
      final snapshot = _ServiceSnapshot.capture(service);
      service.response = _yamlFor('New Node');
      SubscriptionProcessing.workerStartDelayForTesting =
          const Duration(seconds: 5);
      addTearDown(() =>
          SubscriptionProcessing.workerStartDelayForTesting = Duration.zero);
      final cancellation = SubscriptionRefreshCancellation();
      final refresh =
          service.refreshAllSubscriptions(cancellation: cancellation);
      final expectation =
          expectLater(refresh, throwsA(isA<SubscriptionRefreshCancelled>()));
      await _waitForProcessingWorkers(active: true);
      cancellation.cancel();
      await expectation;
      await _waitForProcessingWorkers(active: false);
      snapshot.expectUnchanged(service);
      expect(service.fetchCalls, 0);
      expect(service.cachedYaml, snapshot.rawYaml);
    });

    test(
        'large processed cache rolls back revision and latency on metadata failure',
        () async {
      service.response = _largeYaml(3000);
      await service.refreshAllSubscriptions();
      service.allNodes.first.latency = 37;
      final snapshot = _ServiceSnapshot.capture(service);
      final displayRevision = service.displayRevision;
      service.response = _largeYaml(3000).replaceAll('node-', 'changed-');
      service.failMetadataWrites = true;
      await expectLater(service.refreshAllSubscriptions(),
          throwsA(isA<FileSystemException>()));
      snapshot.expectUnchanged(service);
      expect(service.displayRevision, displayRevision);
      expect(service.allNodes.first.latency, 37);
      service.failMetadataWrites = false;
      service.response = snapshot.rawYaml;
      await service.refreshAllSubscriptions();
      expect(service.revision, snapshot.revision);
      expect(service.allNodes.first.latency, 37);
    });

    test(
        'targeted refresh fetches only selected source and retains other nodes',
        () async {
      final backup = await service.addSubscription(
          'Backup', 'https://backup.example.com/sub');
      service.responses = {
        'https://feed.example.com/sub': _yamlFor('Primary Old'),
        'https://backup.example.com/sub': _yamlFor('Backup Old'),
      };
      await service.refreshAllSubscriptionsDetailed();
      final calls = service.fetchCalls;
      service.responses = {
        'https://feed.example.com/sub': Exception('must not be fetched'),
        'https://backup.example.com/sub': _yamlFor('Backup New'),
      };
      await service.refreshAllSubscriptionsDetailed(onlyId: backup.id);
      expect(service.fetchCalls, calls + 1);
      expect(service.allNodes.map((node) => node.name),
          containsAll(['Primary Old', 'Backup New']));
      expect(service.allNodes.map((node) => node.name),
          isNot(contains('Backup Old')));
      final cancellation = SubscriptionRefreshCancellation()..cancel();
      await expectLater(
          service.refreshAllSubscriptionsDetailed(
              onlyId: backup.id, cancellation: cancellation),
          throwsA(isA<SubscriptionRefreshCancelled>()));
      expect(service.fetchCalls, calls + 1);
    });

    test('partial fetch commits fresh sources while preserving failed sources',
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
      expect(result.yaml, service.rawYaml);
      expect(result.successfulSubscriptionNames, ['Primary']);
      expect(result.failures, hasLength(1));
      expect(result.failures.single.subscriptionName, 'Backup');
      expect(result.failures.single.message, contains('暂时无法确定原因'));
      expect(result.failures.single.diagnosticCode, 'SUB_UNKNOWN');
      expect(service.allNodes.map((node) => node.name), ['New Primary']);
      expect(service.cachedYaml, result.yaml);
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

    test('deleting a subscription does not fetch uncached survivors', () async {
      final removed = service.subscriptions.single;
      final survivor = await service.addSubscription(
        'Backup',
        'https://backup.example.com/sub',
      );
      service.responses = {
        survivor.url: Exception('offline'),
      };
      final fetchCalls = service.fetchCalls;
      await service.removeSubscription(removed.id);
      expect(service.subscriptions.single.id, survivor.id);
      expect(service.allNodes, isEmpty);
      expect(service.fetchCalls, fetchCalls);
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
      await service.addSubscription('Queue drain', 'https://drain.invalid/sub');
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
      await service.addSubscription('Queue drain', 'https://drain.invalid/sub');
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

    test('remove waits for an in-flight refresh and keeps cached survivors',
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
        ['Primary During Refresh'],
      );
    });

    test('update waits for an in-flight refresh before replacing metadata',
        () async {
      final fetchStarted = Completer<void>();
      final response = Completer<String?>();
      service
        ..fetchStarted = fetchStarted
        ..queuedResponses = [
          response.future,
          Future<String?>.value(_yamlFor('Updated Source Node')),
        ];

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
        ['Updated Source Node'],
      );
      expect(service.fetchCalls, 2);
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

    test('successful CRUD purges fetched names for inactive token URLs',
        () async {
      service
        ..fetchedProfileName = 'Fetched Profile'
        ..response = _yamlFor('Fetched Node');
      await service.refreshAllSubscriptions();
      expect(service.retainedFetchedProfileNameCount, 1);

      final original = service.subscriptions.single;
      await service.updateSubscription(
        Subscription(
          id: original.id,
          name: original.name,
          url: 'https://replacement.example.com/sub?token=new-secret',
        ),
      );
      // The previous URL is purged; the newly fetched URL owns one entry.
      expect(service.retainedFetchedProfileNameCount, 1);

      service.fetchedProfileName = 'Replacement Profile';
      await service.refreshAllSubscriptions();
      expect(service.retainedFetchedProfileNameCount, 1);

      await service.removeSubscription(original.id);
      expect(service.retainedFetchedProfileNameCount, 0);
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

    test('unrunnable edits cannot hide behind another valid node', () async {
      await service.setRawYaml('${_yamlFor('Old Node')}'
          '  - {name: Other, type: socks5, server: other.invalid, port: 443}\n');
      final before = service.rawYaml;
      final config = {
        'name': 'Edited Node',
        'type': 'unsupported-type',
        'server': 'edited.invalid',
        'port': 443,
      };
      expect(() => service.validateNodeUpdate('Old Node', config),
          throwsA(isA<FormatException>()));
      await expectLater(service.updateNode('Old Node', config),
          throwsA(isA<FormatException>()));
      expect(service.rawYaml, before);
      expect(service.allNodes.map((node) => node.name), ['Old Node', 'Other']);
    });

    test('edited node cannot claim an SSRVPN runtime group name', () async {
      await expectLater(
        service.updateNode('Old Node', {
          'name': 'PROXY',
          'type': 'ss',
          'server': 'edited.example.com',
          'port': 443,
          'cipher': 'aes-256-gcm',
          'password': 'secret',
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('运行时保留名称'),
          ),
        ),
      );

      originalState.expectUnchanged(service);
    });

    test('edited node cannot obfuscate a reserved runtime name', () async {
      await expectLater(
        service.updateNode('Old Node', {
          'name': 'P\tROXY',
          'type': 'ss',
          'server': 'edited.example.com',
          'port': 443,
          'cipher': 'aes-256-gcm',
          'password': 'secret',
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('运行时保留名称'),
          ),
        ),
      );

      originalState.expectUnchanged(service);
    });

    test('edited node detects duplicates after name canonicalization',
        () async {
      const yaml = r'''
proxies:
  - {name: Old Node, type: ss, server: old.example.com, port: 443, cipher: aes-256-gcm, password: secret}
  - {name: "D\u0001uplicate", type: ss, server: duplicate.example.com, port: 443, cipher: aes-256-gcm, password: secret}
''';
      await service.setRawYaml(yaml);
      final before = service.rawYaml;

      await expectLater(
        service.updateNode('Old Node', {
          'name': 'Duplicate',
          'type': 'ss',
          'server': 'edited.example.com',
          'port': 443,
          'cipher': 'aes-256-gcm',
          'password': 'secret',
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('节点备注名已存在'),
          ),
        ),
      );

      expect(service.rawYaml, before);
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

Future<void> _waitForProcessingWorkers({required bool active}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  bool matches() => active
      ? SubscriptionProcessing.activeWorkerCount > 0
      : SubscriptionProcessing.activeWorkerCount == 0 &&
          SubscriptionProcessing.pendingWorkerCount == 0;
  while (!matches() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(matches(), isTrue, reason: 'worker lifecycle did not settle');
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
  bool Function()? fetchProbe;
  bool? fetchProbeResult;
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
    fetchProbeResult = fetchProbe?.call();
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
