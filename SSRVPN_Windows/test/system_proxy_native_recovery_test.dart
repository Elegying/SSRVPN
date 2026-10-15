import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/system_proxy_service.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp("SSRVPN 用户's recovery ");
  });
  tearDown(() => directory.delete(recursive: true));

  for (final outcome in [0, 1, 2, 5, 6]) {
    test('native recovery outcome $outcome bypasses slow PowerShell', () async {
      var calls = 0;
      final service = SystemProxyService.forTesting(
          isWindows: true,
          localAppData: directory.path,
          scriptRunner: (_) async =>
              throw StateError('PowerShell must not run'),
          nativeRecovery: () async {
            calls++;
            return outcome;
          });
      await service.initialize(directory.path);
      final complete = outcome == 1 || outcome == 5;
      expect(service.recoveryPending, !complete);
      expect(service.endpointSafeWithPendingRecovery,
          outcome == 2 || outcome == 6);
      expect(service.ownershipChangedSinceLastAcquisition, outcome >= 4);
      expect(await service.clearSystemProxy(), complete);
      expect(calls, 2);
    });
  }

  test('native failure preserves recovery record until a successful retry',
      () async {
    final file =
        File('${directory.path}/SSRVPN/runtime/system_proxy_backup.json');
    await file.parent.create(recursive: true);
    await file.writeAsString('keep recovery data');
    var fail = true;
    final service = SystemProxyService.forTesting(
        isWindows: true,
        localAppData: directory.path,
        scriptRunner: (_) async => throw StateError('PowerShell must not run'),
        nativeRecovery: () async {
          if (fail) throw StateError('access denied');
          await file.delete();
          return 1;
        });
    await service.initialize(directory.path);
    expect(service.recoveryPending, isTrue);
    expect(await file.readAsString(), 'keep recovery data');
    fail = false;
    expect(await service.retryPendingRecovery(), isTrue);
    expect(service.recoveryPending, isFalse);
  });

  test('native recovery is serialized and does not hold the Dart file lock',
      () async {
    final entered = Completer<void>(), resume = Completer<void>();
    var calls = 0;
    final service = SystemProxyService.forTesting(
        isWindows: true,
        localAppData: directory.path,
        scriptRunner: (_) async => throw StateError('PowerShell must not run'),
        nativeRecovery: () async {
          final lock = await File(
                  '${directory.path}/SSRVPN/runtime/system_proxy_transaction.lock')
              .open(mode: FileMode.append);
          await lock.lock(FileLock.exclusive);
          await lock.unlock();
          await lock.close();
          if (++calls == 1) {
            entered.complete();
            await resume.future;
          }
          return 1;
        });
    final initialization = service.initialize(directory.path);
    await entered.future;
    final clear = service.clearSystemProxy();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    resume.complete();
    await initialization;
    expect(await clear, isTrue);
    expect(calls, 2);
  });
}
