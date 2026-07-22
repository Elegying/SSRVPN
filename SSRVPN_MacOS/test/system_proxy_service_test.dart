import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/services/system_proxy_service.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  test(
      'effective proxy ownership detects an external change without mutating it',
      () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'ssrvpn_macos_proxy_effective_ownership_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    var effectiveProxyOwned = true;
    var effectiveProxyReadable = true;
    final mutationCommands = <List<String>>[];
    final service = SystemProxyService(
      beginProxyLifecycleTransaction: () async => 'test-proxy-lease',
      endProxyLifecycleTransaction: (_) async => true,
      effectiveProxyRunner: () async => ProcessResult(
        1,
        effectiveProxyReadable ? 0 : 124,
        effectiveProxyOwned
            ? '''<dictionary> {
  HTTPEnable : 1
  HTTPPort : 7890
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7890
  HTTPSProxy : 127.0.0.1
  SOCKSEnable : 1
  SOCKSPort : 7890
  SOCKSProxy : 127.0.0.1
}'''
            : '''<dictionary> {
  HTTPEnable : 1
  HTTPPort : 8888
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 8888
  HTTPSProxy : 127.0.0.1
  SOCKSEnable : 1
  SOCKSPort : 8888
  SOCKSProxy : 127.0.0.1
}''',
        '',
      ),
      networkSetupRunner: (arguments) async {
        if (arguments.first == '-listallnetworkservices') {
          return ProcessResult(1, 0, 'Wi-Fi\n', '');
        }
        if (arguments.first.startsWith('-get')) {
          return ProcessResult(
            1,
            0,
            'Enabled: No\nServer: \nPort: 0\n',
            '',
          );
        }
        mutationCommands.add(List<String>.from(arguments));
        return ProcessResult(1, 0, '', '');
      },
    );
    await service.initialize(tempDirectory.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);
    final mutationsAfterSetup = mutationCommands.length;

    expect(
      await service.currentSystemProxyOwnershipStatus(),
      SystemProxyOwnershipStatus.owned,
    );
    expect(await service.isCurrentSystemProxyOwned(), isTrue);

    effectiveProxyOwned = false;
    expect(
      await service.currentSystemProxyOwnershipStatus(),
      SystemProxyOwnershipStatus.externallyChanged,
    );
    expect(await service.isCurrentSystemProxyOwned(), isFalse);
    expect(mutationCommands, hasLength(mutationsAfterSetup));
    expect(service.lastError, contains('关闭或修改'));

    effectiveProxyReadable = false;
    expect(
      await service.currentSystemProxyOwnershipStatus(),
      SystemProxyOwnershipStatus.unavailable,
    );
    expect(mutationCommands, hasLength(mutationsAfterSetup));
  });

  test('native lifecycle lease brackets every proxy mutation', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'ssrvpn_macos_proxy_lifecycle_lease_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final beginBarrier = Completer<void>();
    var holdBegin = false;
    var tokenCounter = 0;
    final events = <String>[];
    final service = _testSystemProxyService(
      beginProxyLifecycleTransaction: () async {
        final token = 'lease-${++tokenCounter}';
        events.add('begin:$token');
        if (holdBegin) await beginBarrier.future;
        return token;
      },
      endProxyLifecycleTransaction: (token) async {
        events.add('end:$token');
        return true;
      },
      networkSetupRunner: (arguments) async {
        events.add('network:${arguments.join(' ')}');
        if (arguments.first == '-listallnetworkservices') {
          return ProcessResult(1, 0, 'Wi-Fi\n', '');
        }
        if (arguments.first.startsWith('-get')) {
          return ProcessResult(
            1,
            0,
            'Enabled: No\nServer: \nPort: 0\n',
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );
    await service.initialize(tempDirectory.path);
    events.clear();
    holdBegin = true;

    final setting = service.setSystemProxy('127.0.0.1', 7890);
    await Future<void>.delayed(Duration.zero);

    expect(events, ['begin:lease-2']);
    beginBarrier.complete();
    expect(await setting, isTrue);
    expect(events.first, 'begin:lease-2');
    expect(events.last, 'end:lease-2');
    expect(events.where((event) => event.startsWith('begin:')), hasLength(1));
    expect(events.where((event) => event.startsWith('end:')), hasLength(1));
    expect(
      events.indexWhere((event) => event.startsWith('network:')),
      greaterThan(0),
    );
  });

  test('native lifecycle lease is released after proxy setup failure',
      () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'ssrvpn_macos_proxy_lifecycle_failure_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final events = <String>[];
    var tokenCounter = 0;
    final service = _testSystemProxyService(
      beginProxyLifecycleTransaction: () async {
        final token = 'lease-${++tokenCounter}';
        events.add('begin:$token');
        return token;
      },
      endProxyLifecycleTransaction: (token) async {
        events.add('end:$token');
        return true;
      },
      networkSetupRunner: (arguments) async {
        events.add('network:${arguments.join(' ')}');
        if (arguments.first == '-listallnetworkservices') {
          return ProcessResult(1, 0, 'Wi-Fi\n', '');
        }
        if (arguments.first.startsWith('-get')) {
          throw StateError('controlled proxy read failure');
        }
        return ProcessResult(1, 0, '', '');
      },
    );
    await service.initialize(tempDirectory.path);
    events.clear();

    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);

    expect(events.first, 'begin:lease-2');
    expect(events.last, 'end:lease-2');
    expect(events.where((event) => event.startsWith('begin:')), hasLength(1));
    expect(events.where((event) => event.startsWith('end:')), hasLength(1));
  });

  test('ownership-only proxy snapshot stays unresolved without commands',
      () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'ssrvpn_macos_proxy_ownership_only_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final snapshot = File('${tempDirectory.path}/system_proxy.json');
    final originalSnapshot = jsonEncode({
      '_ownedProxyHost': '127.0.0.1',
      '_ownedProxyPort': 7890,
      '_ownerPid': 4242,
    });
    await snapshot.writeAsString(originalSnapshot, flush: true);
    final commands = <List<String>>[];
    final service = _testSystemProxyService(
      networkSetupRunner: (arguments) async {
        commands.add(arguments);
        return ProcessResult(1, 1, '', 'must not run');
      },
    );

    await service.initialize(tempDirectory.path);

    expect(commands, isEmpty);
    expect(await snapshot.readAsString(), originalSnapshot);
    expect(service.recoveryPending, isTrue);
    expect(service.lastError, contains('有效网络服务'));
  });

  for (final invalidOwnership in <String, Map<String, Object?>>{
    'blank host': {
      '_ownedProxyHost': '   ',
      '_ownedProxyPort': 7890,
    },
    'negative port': {
      '_ownedProxyHost': '127.0.0.1',
      '_ownedProxyPort': -1,
    },
    'oversized port': {
      '_ownedProxyHost': '127.0.0.1',
      '_ownedProxyPort': 70000,
    },
    'boolean port': {
      '_ownedProxyHost': '127.0.0.1',
      '_ownedProxyPort': true,
    },
  }.entries) {
    test('${invalidOwnership.key} ownership fails before network commands',
        () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_proxy_invalid_ownership_',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));
      final snapshot = File('${tempDirectory.path}/system_proxy.json');
      final originalSnapshot = jsonEncode({
        ...invalidOwnership.value,
        'Wi-Fi': {
          'web': {'enabled': false, 'server': '', 'port': 0},
          'secureWeb': {'enabled': false, 'server': '', 'port': 0},
          'socks': {'enabled': false, 'server': '', 'port': 0},
        },
      });
      await snapshot.writeAsString(originalSnapshot, flush: true);
      final commands = <List<String>>[];
      final service = _testSystemProxyService(
        networkSetupRunner: (arguments) async {
          commands.add(arguments);
          return ProcessResult(1, 1, '', 'must not run');
        },
      );

      await service.initialize(tempDirectory.path);

      expect(commands, isEmpty);
      expect(await snapshot.readAsString(), originalSnapshot);
      expect(service.recoveryPending, isTrue);
      expect(service.lastError, contains('无法确认代理归属'));
    });
  }

  for (final invalidService in <String, Object?>{
    'service is not a map': 'invalid',
    'service misses socks state': {
      'web': {'enabled': false, 'server': '', 'port': 0},
      'secureWeb': {'enabled': false, 'server': '', 'port': 0},
    },
    'service contains an invalid state map': {
      'web': {'enabled': 'false', 'server': '', 'port': 0},
      'secureWeb': {'enabled': false, 'server': '', 'port': 0},
      'socks': {'enabled': false, 'server': '', 'port': 0},
    },
    'enabled proxy state contains only whitespace server': {
      'web': {'enabled': true, 'server': '   ', 'port': 8080},
      'secureWeb': {'enabled': false, 'server': '', 'port': 0},
      'socks': {'enabled': false, 'server': '', 'port': 0},
    },
    'service contains an extra state': {
      'web': {'enabled': false, 'server': '', 'port': 0},
      'secureWeb': {'enabled': false, 'server': '', 'port': 0},
      'socks': {'enabled': false, 'server': '', 'port': 0},
      'futureState': <String, Object?>{},
    },
    'proxy state contains an extra field': {
      'web': {
        'enabled': false,
        'server': '',
        'port': 0,
        'futureField': true,
      },
      'secureWeb': {'enabled': false, 'server': '', 'port': 0},
      'socks': {'enabled': false, 'server': '', 'port': 0},
    },
  }.entries) {
    test('${invalidService.key} fails closed before network changes', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_proxy_invalid_service_',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));
      final snapshot = File('${tempDirectory.path}/system_proxy.json');
      final originalSnapshot = jsonEncode({
        '_ownedProxyHost': '127.0.0.1',
        '_ownedProxyPort': 7890,
        'Wi-Fi': invalidService.value,
      });
      await snapshot.writeAsString(originalSnapshot, flush: true);
      final commands = <List<String>>[];
      final service = _testSystemProxyService(
        networkSetupRunner: (arguments) async {
          commands.add(arguments);
          return ProcessResult(1, 1, '', 'must not run');
        },
      );

      await service.initialize(tempDirectory.path);

      expect(commands, isEmpty);
      expect(await snapshot.readAsString(), originalSnapshot);
      expect(service.recoveryPending, isTrue);
      expect(service.lastError, contains('格式无效'));
    });
  }

  test('underscore-prefixed network service is restored as a real service',
      () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'ssrvpn_macos_proxy_underscore_service_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final snapshot = File('${tempDirectory.path}/system_proxy.json');
    await _writeOwnedSnapshot(snapshot, serviceName: '_Wi-Fi');
    final commands = <String>[];
    final service = _testSystemProxyService(
      networkSetupRunner: (arguments) async {
        commands.add(arguments.join(' '));
        if (arguments.first == '-listallnetworkservices') {
          return ProcessResult(1, 0, '_Wi-Fi\n', '');
        }
        if (arguments.first.startsWith('-get')) {
          return ProcessResult(
            1,
            0,
            'Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n',
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(tempDirectory.path);

    expect(await snapshot.exists(), isFalse);
    expect(service.recoveryPending, isFalse);
    expect(
      commands,
      [
        '-listallnetworkservices',
        '-getwebproxy _Wi-Fi',
        '-setwebproxystate _Wi-Fi off',
        '-getsecurewebproxy _Wi-Fi',
        '-setsecurewebproxystate _Wi-Fi off',
        '-getsocksfirewallproxy _Wi-Fi',
        '-setsocksfirewallproxystate _Wi-Fi off',
      ],
    );
  });

  test('recovery preserves an externally replaced proxy endpoint', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'ssrvpn_macos_proxy_external_replacement_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final snapshot = File('${tempDirectory.path}/system_proxy.json');
    await _writeOwnedSnapshot(snapshot);
    final commands = <String>[];
    final service = _testSystemProxyService(
      networkSetupRunner: (arguments) async {
        commands.add(arguments.join(' '));
        switch (arguments.first) {
          case '-listallnetworkservices':
            return ProcessResult(1, 0, 'Wi-Fi\n', '');
          case '-getwebproxy':
            return ProcessResult(
              1,
              0,
              'Enabled: Yes\nServer: 127.0.0.1\nPort: 8888\n',
              '',
            );
          case '-getsecurewebproxy':
          case '-getsocksfirewallproxy':
            return ProcessResult(
              1,
              0,
              'Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n',
              '',
            );
          default:
            return ProcessResult(1, 0, '', '');
        }
      },
    );

    await service.initialize(tempDirectory.path);

    expect(await snapshot.exists(), isFalse);
    expect(service.recoveryPending, isFalse);
    expect(service.ownershipChangedSinceLastAcquisition, isTrue);
    expect(
      commands.where((command) => command.startsWith('-setwebproxy')),
      isEmpty,
    );
    expect(commands, contains('-setsecurewebproxystate Wi-Fi off'));
    expect(commands, contains('-setsocksfirewallproxystate Wi-Fi off'));
  });

  for (final reservedName in const [
    '_ownedProxyHost',
    '_ownedProxyPort',
    '_ownerPid',
  ]) {
    test('reserved snapshot key service $reservedName is rejected before setup',
        () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_proxy_reserved_service_',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));
      final commands = <String>[];
      final service = _testSystemProxyService(
        networkSetupRunner: (arguments) async {
          commands.add(arguments.join(' '));
          if (arguments.first == '-listallnetworkservices') {
            return ProcessResult(1, 0, '$reservedName\n', '');
          }
          return ProcessResult(1, 0, '', '');
        },
      );
      await service.initialize(tempDirectory.path);

      expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);

      expect(commands, ['-listallnetworkservices']);
      expect(service.isProxyEnabled, isFalse);
      expect(service.lastError, contains('保留字段冲突'));
      expect(
        await File('${tempDirectory.path}/system_proxy.json').exists(),
        isFalse,
      );
    });
  }

  test('legacy proxy snapshot without ownership remains unresolved', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'ssrvpn_macos_proxy_legacy_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final snapshot = File('${tempDirectory.path}/system_proxy.json');
    final originalSnapshot = jsonEncode({
      'Wi-Fi': {
        'web': {'enabled': true, 'server': '127.0.0.1', 'port': 7890},
      },
    });
    await snapshot.writeAsString(originalSnapshot, flush: true);

    final service = _testSystemProxyService();
    await service.initialize(tempDirectory.path);

    expect(await snapshot.readAsString(), originalSnapshot);
    expect(service.recoveryPending, isTrue);
    expect(service.lastError, contains('无法确认代理归属'));
  });

  test(
    'concurrent proxy clears share one successful recovery operation',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_proxy_single_flight_',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));
      final snapshot = File('${tempDirectory.path}/system_proxy.json');
      final listStarted = Completer<void>();
      final releaseList = Completer<void>();
      final commands = <String>[];
      final service = _testSystemProxyService(
        networkSetupRunner: (arguments) async {
          commands.add(arguments.join(' '));
          if (arguments.first == '-listallnetworkservices') {
            if (!listStarted.isCompleted) listStarted.complete();
            await releaseList.future;
            return ProcessResult(1, 0, 'Wi-Fi\n', '');
          }
          if (arguments.first.startsWith('-get')) {
            return ProcessResult(
              1,
              0,
              'Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n',
              '',
            );
          }
          return ProcessResult(1, 0, '', '');
        },
      );
      await service.initialize(tempDirectory.path);
      await _writeOwnedSnapshot(snapshot);

      final first = service.clearSystemProxy();
      await listStarted.future;
      final second = service.clearSystemProxy();
      expect(identical(first, second), isTrue);
      await Future<void>.delayed(Duration.zero);
      releaseList.complete();

      expect(await Future.wait([first, second]), [isTrue, isTrue]);
      expect(
        commands,
        [
          '-listallnetworkservices',
          '-getwebproxy Wi-Fi',
          '-setwebproxystate Wi-Fi off',
          '-getsecurewebproxy Wi-Fi',
          '-setsecurewebproxystate Wi-Fi off',
          '-getsocksfirewallproxy Wi-Fi',
          '-setsocksfirewallproxystate Wi-Fi off',
        ],
      );
      expect(await snapshot.exists(), isFalse);
      expect(service.recoveryPending, isFalse);
      expect(service.lastError, isNull);
    },
  );

  test('failed concurrent proxy clear remains retryable', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'ssrvpn_macos_proxy_single_flight_retry_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final snapshot = File('${tempDirectory.path}/system_proxy.json');
    var allowRecovery = false;
    var listCalls = 0;
    final firstListStarted = Completer<void>();
    final releaseFirstList = Completer<void>();
    final service = _testSystemProxyService(
      networkSetupRunner: (arguments) async {
        if (arguments.first == '-listallnetworkservices') {
          listCalls++;
          if (!allowRecovery) {
            if (!firstListStarted.isCompleted) firstListStarted.complete();
            await releaseFirstList.future;
            return ProcessResult(1, 1, '', 'network services unavailable');
          }
          return ProcessResult(1, 0, 'Wi-Fi\n', '');
        }
        if (arguments.first.startsWith('-get')) {
          return ProcessResult(
            1,
            0,
            'Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n',
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );
    await service.initialize(tempDirectory.path);
    await _writeOwnedSnapshot(snapshot);

    final first = service.clearSystemProxy();
    await firstListStarted.future;
    final second = service.clearSystemProxy();
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    releaseFirstList.complete();

    expect(await Future.wait([first, second]), [isFalse, isFalse]);
    expect(listCalls, 1);
    expect(await snapshot.exists(), isTrue);
    expect(service.recoveryPending, isTrue);
    expect(service.lastError, contains('network services unavailable'));

    allowRecovery = true;
    expect(await service.clearSystemProxy(), isTrue);
    expect(listCalls, 2);
    expect(await snapshot.exists(), isFalse);
    expect(service.recoveryPending, isFalse);
    expect(service.lastError, isNull);
  });

  group('unsafe proxy recovery state paths fail closed', () {
    test('directory is preserved', () async {
      await _expectUnsafeStatePathIsPreserved(
          (path) => Directory(path).create());
    });

    test('dangling symbolic link is preserved', () async {
      await _expectUnsafeStatePathIsPreserved(
        (path) => Link(path).create('$path.missing'),
      );
    });

    test('FIFO is preserved', () async {
      await _expectUnsafeStatePathIsPreserved((path) async {
        final result = await Process.run('/usr/bin/mkfifo', [path]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
      });
    });

    test('unreadable regular file is preserved', () async {
      await _expectUnsafeStatePathIsPreserved((path) async {
        await File(path).writeAsString('{}', flush: true);
        final result = await Process.run('/bin/chmod', ['000', path]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
      });
    });

    test('oversized regular file is preserved', () async {
      await _expectUnsafeStatePathIsPreserved(
        (path) => File(path).writeAsBytes(
          List<int>.filled(1024 * 1024 + 1, 0x20),
          flush: true,
        ),
        expectedErrorFragment: '超过 1 MiB',
      );
    });

    for (final mode in ['0664', '0646']) {
      test('$mode group or other writable file is preserved', () async {
        await _expectUnsafeStatePathIsPreserved(
          (path) async {
            await _writeOwnedSnapshot(File(path));
            final result = await Process.run('/bin/chmod', [mode, path]);
            expect(result.exitCode, 0, reason: result.stderr.toString());
          },
          expectedErrorFragment: 'group/other 可写',
        );
      });
    }

    test('0644 regular file remains eligible for recovery', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_proxy_safe_mode_',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));
      final snapshot = File('${tempDirectory.path}/system_proxy.json');
      await _writeOwnedSnapshot(snapshot);
      final chmod = await Process.run('/bin/chmod', ['0644', snapshot.path]);
      expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
      final service = _testSystemProxyService(
        networkSetupRunner: _successfulNetworkSetupRunner,
      );

      await service.initialize(tempDirectory.path);

      expect(await snapshot.exists(), isFalse);
      expect(service.recoveryPending, isFalse);
      expect(service.lastError, isNull);
    });
  });
}

Future<void> _writeOwnedSnapshot(
  File snapshot, {
  String serviceName = 'Wi-Fi',
}) =>
    snapshot.writeAsString(
      jsonEncode({
        '_ownedProxyHost': '127.0.0.1',
        '_ownedProxyPort': 7890,
        serviceName: {
          'web': {'enabled': false, 'server': '', 'port': 0},
          'secureWeb': {'enabled': false, 'server': '', 'port': 0},
          'socks': {'enabled': false, 'server': '', 'port': 0},
        },
      }),
      flush: true,
    );

Future<void> _expectUnsafeStatePathIsPreserved(
    Future<void> Function(String path) createStatePath,
    {String? expectedErrorFragment}) async {
  final tempDirectory = await Directory.systemTemp.createTemp(
    'ssrvpn_macos_proxy_unsafe_state_',
  );
  addTearDown(() => tempDirectory.delete(recursive: true));
  final statePath = '${tempDirectory.path}/system_proxy.json';
  await createStatePath(statePath);

  final service = _testSystemProxyService();
  await service.initialize(tempDirectory.path);

  expect(
    await FileSystemEntity.type(statePath, followLinks: false),
    isNot(FileSystemEntityType.notFound),
  );
  expect(service.recoveryPending, isTrue);
  expect(
    service.lastError,
    expectedErrorFragment == null ? isNotNull : contains(expectedErrorFragment),
  );
}

SystemProxyService _testSystemProxyService({
  MacNetworkSetupRunner? networkSetupRunner,
  MacProxyLifecycleBegin? beginProxyLifecycleTransaction,
  MacProxyLifecycleEnd? endProxyLifecycleTransaction,
}) =>
    SystemProxyService(
      networkSetupRunner: networkSetupRunner,
      beginProxyLifecycleTransaction:
          beginProxyLifecycleTransaction ?? () async => 'test-proxy-lease',
      endProxyLifecycleTransaction:
          endProxyLifecycleTransaction ?? (_) async => true,
    );

Future<ProcessResult> _successfulNetworkSetupRunner(
  List<String> arguments,
) async {
  if (arguments.first == '-listallnetworkservices') {
    return ProcessResult(1, 0, 'Wi-Fi\n', '');
  }
  if (arguments.first.startsWith('-get')) {
    return ProcessResult(
      1,
      0,
      'Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n',
      '',
    );
  }
  return ProcessResult(1, 0, '', '');
}
