import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';
import 'package:ssrvpn_windows/src/services/windows_core_pid_record.dart';

void main() {
  const canonicalPath = r'C:\Program Files\SSRVPN\bin\mihomo.exe';

  test('versioned core PID record round-trips every process identity field',
      () {
    const record = WindowsCorePidRecord(
      pid: 4242,
      creationTimeUtcFileTime: '134145678901234567',
      canonicalExecutablePath: canonicalPath,
    );

    final encoded = record.encode();
    final decoded = WindowsCorePidRecord.tryParse(encoded);

    expect(decoded, record);
    expect(jsonDecode(encoded), {
      'version': 1,
      'pid': 4242,
      'creationTimeUtcFileTime': '134145678901234567',
      'canonicalExecutablePath': canonicalPath,
    });
  });

  test('same PID and path from another creation time is not the same process',
      () {
    const recorded = WindowsCorePidRecord(
      pid: 4242,
      creationTimeUtcFileTime: '134145678901234567',
      canonicalExecutablePath: canonicalPath,
    );
    const reusedPid = WindowsCorePidRecord(
      pid: 4242,
      creationTimeUtcFileTime: '134145678901234999',
      canonicalExecutablePath: canonicalPath,
    );

    expect(recorded.hasSameIdentity(reusedPid), isFalse);
  });

  test('Windows executable path identity is case-insensitive', () {
    const recorded = WindowsCorePidRecord(
      pid: 4242,
      creationTimeUtcFileTime: '134145678901234567',
      canonicalExecutablePath: canonicalPath,
    );
    const live = WindowsCorePidRecord(
      pid: 4242,
      creationTimeUtcFileTime: '134145678901234567',
      canonicalExecutablePath: r'c:\program files\ssrvpn\BIN\MIHOMO.EXE',
    );

    expect(recorded.hasSameIdentity(live), isTrue);
  });

  test('legacy and malformed PID records fail closed', () {
    expect(WindowsCorePidRecord.tryParse('4242\n'), isNull);
    expect(WindowsCorePidRecord.tryParse('{'), isNull);

    const validFields = <String, Object>{
      'version': 1,
      'pid': 4242,
      'creationTimeUtcFileTime': '1',
      'canonicalExecutablePath': canonicalPath,
    };
    final invalidFieldSets = <Map<String, Object>>[
      const {},
      {...validFields, 'version': 2},
      {...validFields, 'creationTimeUtcFileTime': 1},
      {...validFields, 'pid': 1},
      {...validFields, 'creationTimeUtcFileTime': '0'},
      {...validFields, 'canonicalExecutablePath': 'mihomo.exe'},
      {...validFields, 'extra': true},
      {
        'version': 1,
        'pid': 4242,
        'creationTimeUtcFileTime': '1',
      },
    ];
    for (final fields in invalidFieldSets) {
      final contents = jsonEncode(fields);
      expect(jsonDecode(contents), isA<Map<String, dynamic>>());
      expect(
        WindowsCorePidRecord.tryParse(contents),
        isNull,
        reason: fields.toString(),
      );
    }
  });

  test('verified OpenProcess failure treats access denied as an error', () {
    final lifecycleSource = File(
      'lib/services/clash_service_lifecycle.dart',
    ).readAsStringSync();
    final failureStart = lifecycleSource.indexOf(
      'if (process == IntPtr.Zero) {',
    );
    final failureEnd = lifecycleSource.indexOf(
      '    try {',
      failureStart,
    );

    expect(failureStart, greaterThanOrEqualTo(0));
    expect(failureEnd, greaterThan(failureStart));
    final openProcessFailure = lifecycleSource.substring(
      failureStart,
      failureEnd,
    );
    expect(openProcessFailure, contains('Marshal.GetLastWin32Error()'));
    expect(openProcessFailure, contains('if (error == 87) return 1;'));
    expect(openProcessFailure, contains('throw new Win32Exception(error);'));
    expect(openProcessFailure, isNot(contains('if (error == 5) return 1;')));
  });

  test('verified termination fails closed when exit-code query fails', () {
    final lifecycleSource = File(
      'lib/services/clash_service_lifecycle.dart',
    ).readAsStringSync();

    expect(
      lifecycleSource,
      contains('if (!GetExitCodeProcess(process, out exitCode)) {'),
    );
    expect(
      lifecycleSource,
      contains('throw new Win32Exception(Marshal.GetLastWin32Error());'),
    );
  });

  test(
      'cancellation during identity capture waits for durable identity before winning',
      () async {
    const record = WindowsCorePidRecord(
      pid: 4242,
      creationTimeUtcFileTime: '134145678901234567',
      canonicalExecutablePath: canonicalPath,
    );
    final process = _FakeProcess();
    final capture = Completer<WindowsCorePidRecord>();
    final persisted = <WindowsCorePidRecord>[];
    final establishment = WindowsCoreIdentityEstablishment(process);
    var cancelled = false;
    var connectedPublished = false;

    final start = () async {
      await establishment.establish(
        capture: (_) => capture.future,
        persist: (identity) async => persisted.add(identity),
        ensureStartCurrent: () {
          if (cancelled) throw _TestStartCancelled();
        },
      );
      connectedPublished = true;
    }();

    cancelled = true;
    final cancellationExpectation = expectLater(
      start,
      throwsA(isA<_TestStartCancelled>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(persisted, isEmpty);
    expect(connectedPublished, isFalse);

    capture.complete(record);
    await cancellationExpectation;

    expect(persisted, [record]);
    expect(establishment.capturedIdentity, record);
    expect(connectedPublished, isFalse);
  });

  test('identity capture failure terminates only the held Process object',
      () async {
    final process = _FakeProcess(
      onKill: (signal, exit) {
        if (signal == ProcessSignal.sigterm) exit.complete(0);
      },
    );
    final otherProcess = _FakeProcess();
    final establishment = WindowsCoreIdentityEstablishment(process);

    await expectLater(
      establishment.establish(
        capture: (_) async => throw StateError('identity capture failed'),
        persist: (_) async {},
        ensureStartCurrent: () {},
      ),
      throwsStateError,
    );

    expect(establishment.capturedIdentity, isNull);
    expect(establishment.ownsUnidentifiedProcess(process), isTrue);
    expect(establishment.ownsUnidentifiedProcess(otherProcess), isFalse);
    await expectLater(
      establishment.terminateUnidentifiedProcess(
        otherProcess,
        terminate: (_) async => true,
      ),
      throwsStateError,
    );

    final stopped = await establishment.terminateUnidentifiedProcess(
      process,
      terminate: (ownedProcess) => terminateCoreProcess(
        ownedProcess,
        gracefulTimeout: const Duration(milliseconds: 10),
        forcedTimeout: const Duration(milliseconds: 10),
      ),
    );

    expect(stopped, isTrue);
    expect(process.signals, [ProcessSignal.sigterm]);
    expect(otherProcess.signals, isEmpty);
  });
}

final class _TestStartCancelled implements Exception {}

class _FakeProcess implements Process {
  _FakeProcess({this.onKill});

  final void Function(ProcessSignal, Completer<int>)? onKill;
  final Completer<int> _exit = Completer<int>();
  final List<ProcessSignal> signals = [];

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    onKill?.call(signal, _exit);
    return true;
  }

  @override
  int get pid => 4242;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();
}
