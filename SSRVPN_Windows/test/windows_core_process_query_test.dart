import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/src/services/windows_core_identity_failure.dart';
import 'package:ssrvpn_windows/src/services/windows_core_process_query.dart';

void main() {
  const trusted = r'C:\SSRVPN\mihomo.exe';
  WindowsCoreProcessSnapshot snapshot({
    int processPid = 42,
    int session = 7,
    int currentSession = 7,
    String path = trusted,
    BigInt? creation,
  }) =>
      WindowsCoreProcessSnapshot(
        pid: processPid,
        sessionId: session,
        currentSessionId: currentSession,
        creationTime: creation ?? BigInt.parse('134050704292216457'),
        executablePath: path,
      );

  test('native snapshot preserves full creation time and case-insensitive path',
      () {
    final record = queryWindowsCoreIdentity(42, trusted, query: (queriedPid) {
      expect(queriedPid, 42);
      return snapshot(path: r'c:\ssrvpn\MIHOMO.EXE');
    });
    expect(record.pid, 42);
    expect(record.creationTimeUtcFileTime, '134050704292216457');
    expect(record.canonicalExecutablePath, r'c:\ssrvpn\MIHOMO.EXE');
  });

  for (final entry in <String, WindowsCoreProcessSnapshot>{
    'recycled PID': snapshot(processPid: 43),
    'different Windows session': snapshot(session: 8),
    'different executable': snapshot(path: r'C:\Other\mihomo.exe'),
  }.entries) {
    test('rejects ${entry.key} before durable persistence', () {
      expect(
          () =>
              queryWindowsCoreIdentity(42, trusted, query: (_) => entry.value),
          throwsA(isA<WindowsCoreIdentityFailure>().having(
              (e) => e.kind, 'kind', WindowsCoreIdentityFailureKind.mismatch)));
    });
  }

  for (final entry in <String, WindowsCoreProcessSnapshot>{
    'zero creation time': snapshot(creation: BigInt.zero),
    'unsigned overflow':
        snapshot(creation: BigInt.parse('18446744073709551616')),
    'noncanonical path': snapshot(path: r'C:\SSRVPN\..\mihomo.exe'),
    'embedded NUL': snapshot(path: '$trusted\u0000'),
  }.entries) {
    test('rejects ${entry.key} as invalid identity data', () {
      expect(
          () =>
              queryWindowsCoreIdentity(42, trusted, query: (_) => entry.value),
          throwsA(isA<WindowsCoreIdentityFailure>().having((e) => e.kind,
              'kind', WindowsCoreIdentityFailureKind.invalidData)));
    });
  }

  test('native API failures retain typed redacted diagnostics', () {
    expect(
        () => queryWindowsCoreIdentity(42, trusted, query: (_) {
              throw StateError(r'API failed at "C:\Users\private\core.exe"');
            }),
        throwsA(isA<WindowsCoreIdentityFailure>()
            .having(
                (e) => e.kind, 'kind', WindowsCoreIdentityFailureKind.execution)
            .having((e) => e.toString(), 'diagnostic',
                isNot(contains(r'C:\Users\private')))));
  });

  test('platform API either queries the live process or fails closed', () {
    if (Platform.isWindows) {
      final identity =
          queryWindowsCoreIdentity(pid, Platform.resolvedExecutable);
      expect(identity.pid, pid);
      expect(BigInt.parse(identity.creationTimeUtcFileTime),
          greaterThan(BigInt.zero));
      expect(identity.canonicalExecutablePath.toLowerCase(),
          Platform.resolvedExecutable.toLowerCase());
      expect(() => queryWindowsCoreIdentity(0, trusted),
          throwsA(isA<WindowsCoreIdentityFailure>()));
    } else {
      expect(
          () => queryWindowsCoreIdentity(pid, Platform.resolvedExecutable),
          throwsA(isA<WindowsCoreIdentityFailure>().having((e) => e.kind,
              'kind', WindowsCoreIdentityFailureKind.execution)));
    }
  });
}
