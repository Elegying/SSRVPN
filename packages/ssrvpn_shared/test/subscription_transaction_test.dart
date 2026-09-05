import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:ssrvpn_shared/services/subscription_service_base.dart';

const _metadata = 'subscriptions.json';
const _cache = 'subscription_cache.yaml';
const _journal = 'subscription_transaction.json';
const _oldLink = 'socks5://old.invalid:443#Old';
const _newLink = 'socks5://new.invalid:443#New';

void main() {
  late Directory directory;
  late _FaultService service;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ssrvpn-transaction-');
    service = _FaultService();
    await service.init(directory.path);
  });
  tearDown(() async {
    service.dispose();
    await directory.delete(recursive: true);
  });

  for (final checkpoint in [_cache, _metadata]) {
    for (final hasPreviousState in [true, false]) {
      test('restart recovers the pair after $checkpoint, old=$hasPreviousState',
          () async {
        if (hasPreviousState) await service.addSubscription('Old', _oldLink);
        final oldYaml = service.rawYaml;
        final crashed = await Directory.systemTemp.createTemp('ssrvpn-crash-');
        addTearDown(() => crashed.delete(recursive: true));
        var captured = false;
        service.afterWrite = (file) async {
          if (captured || !file.path.endsWith('/$checkpoint')) return;
          captured = true;
          await for (final entry in directory.list()) {
            if (entry is File) {
              await entry
                  .copy('${crashed.path}/${entry.uri.pathSegments.last}');
            }
          }
        };
        await service.addSubscription('New', _newLink);
        expect(captured, isTrue);
        expect(service.allNodes.last.name, 'New');
        expect(await File('${directory.path}/$_journal').exists(), isFalse);
        expect(await File('${crashed.path}/$_journal').exists(), isTrue);

        final recovered = _FaultService();
        addTearDown(recovered.dispose);
        await recovered.init(crashed.path);
        expect(recovered.rawYaml, oldYaml);
        expect(recovered.subscriptions.map((sub) => sub.url),
            hasPreviousState ? [_oldLink] : isEmpty);
        expect(recovered.allNodes.map((node) => node.name),
            hasPreviousState ? ['Old'] : isEmpty);
        expect(await File('${crashed.path}/$_journal').exists(), isFalse);
        if (!hasPreviousState) {
          expect(await File('${crashed.path}/$_metadata').exists(), isFalse);
          expect(await File('${crashed.path}/$_cache').exists(), isFalse);
        }
      });
    }
  }

  test('restart restores a last-source deletion before its commit point',
      () async {
    final old = await service.addSubscription('Old', _oldLink);
    final oldYaml = service.rawYaml;
    final crashed =
        await Directory.systemTemp.createTemp('ssrvpn-delete-crash-');
    addTearDown(() => crashed.delete(recursive: true));
    service.afterClear = () async {
      await for (final entry in directory.list()) {
        if (entry is File) {
          await entry.copy('${crashed.path}/${entry.uri.pathSegments.last}');
        }
      }
    };
    await service.removeSubscription(old.id);
    expect(service.subscriptions, isEmpty);
    expect(await File('${crashed.path}/$_cache').exists(), isFalse);
    expect(await File('${crashed.path}/$_journal').exists(), isTrue);
    final recovered = _FaultService();
    addTearDown(recovered.dispose);
    await recovered.init(crashed.path);
    expect(recovered.rawYaml, oldYaml);
    expect(recovered.subscriptions.single.id, old.id);
    expect(recovered.allNodes.single.name, 'Old');
    expect(await File('${crashed.path}/$_journal').exists(), isFalse);
  });

  test('failed writes retain a recovery record and preserve the original error',
      () async {
    await service.addSubscription('Old', _oldLink);
    final oldYaml = service.rawYaml;
    final revision = service.revision;
    final displayRevision = service.displayRevision;
    var notifications = 0;
    service.addListener(() => notifications++);
    service.failOnMetadata = true;
    await expectLater(
        service.addSubscription('New', _newLink),
        throwsA(isA<FileSystemException>()
            .having((error) => error.message, 'message', 'metadata exploded')));
    expect(service.rawYaml, oldYaml);
    expect(service.subscriptions.single.url, _oldLink);
    expect(service.revision, revision);
    expect(service.displayRevision, displayRevision);
    expect(notifications, 0);
    expect(await File('${directory.path}/$_journal').exists(), isTrue);
    final recovered = _FaultService();
    addTearDown(recovered.dispose);
    await recovered.init(directory.path);
    expect(recovered.rawYaml, oldYaml);
    expect(recovered.subscriptions.single.url, _oldLink);
    expect(await File('${directory.path}/$_journal').exists(), isFalse);
  });

  test('listeners see a committed pair and never an intermediate write',
      () async {
    await service.addSubscription('Old', _oldLink);
    var notifications = 0;
    service.addListener(() {
      notifications++;
      expect(File('${directory.path}/$_journal').existsSync(), isFalse);
      expect(File('${directory.path}/$_cache').readAsStringSync(),
          service.rawYaml);
      final saved =
          jsonDecode(File('${directory.path}/$_metadata').readAsStringSync())
              as List;
      expect(saved.map((entry) => entry['url']),
          service.subscriptions.map((sub) => sub.url));
    });
    await service.addSubscription('New', _newLink);
    expect(notifications, 1);
    await service.removeSubscription(service.subscriptions.first.id);
    expect(notifications, 2);
  });

  test('invalid recovery record fails before altering either state file',
      () async {
    await service.addSubscription('Old', _oldLink);
    final metadata = await File('${directory.path}/$_metadata').readAsString();
    final yaml = await File('${directory.path}/$_cache').readAsString();
    // The first entry is valid; the second is not. Validate the entire record
    // before restoring the first file.
    await File('${directory.path}/$_journal').writeAsString(jsonEncode({
      'version': 1,
      'files': {_metadata: '[]', _cache: 42},
    }));
    final recovered = _FaultService();
    addTearDown(recovered.dispose);
    await expectLater(recovered.init(directory.path), throwsFormatException);
    expect(await File('${directory.path}/$_metadata').readAsString(), metadata);
    expect(await File('${directory.path}/$_cache').readAsString(), yaml);
    expect(await File('${directory.path}/$_journal').exists(), isTrue);
    // A failure before queue admission must not leave the caller waiting for
    // the two-minute refresh deadline or start a network request.
    await expectLater(
        service
            .refreshAllSubscriptionsDetailed()
            .timeout(const Duration(seconds: 1)),
        throwsFormatException);
  });
}

class _FaultService extends SubscriptionServiceBase {
  Future<void> Function(File)? afterWrite;
  Future<void> Function()? afterClear;
  bool failOnMetadata = false;
  bool failAllWrites = false;

  @override
  Future<void> clearCachedNodes() async {
    await super.clearCachedNodes();
    await afterClear?.call();
  }

  @override
  Future<String?> fetchSubscription(
    String url, {
    int maxRetries = 3,
    SubscriptionRefreshControl? control,
  }) async =>
      throw StateError('local transactions must not fetch');

  @override
  Future<void> writeStringAtomically(File file, String content) async {
    if (failAllWrites) throw const FileSystemException('rollback unavailable');
    if (failOnMetadata && file.path.endsWith('/$_metadata')) {
      failAllWrites = true;
      throw const FileSystemException('metadata exploded');
    }
    await super.writeStringAtomically(file, content);
    await afterWrite?.call(file);
  }
}
