import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int windowsCorePidRecordVersion = 1;
const int maxWindowsCorePidRecordBytes = 4096;
final BigInt _windowsFileTimeUnixEpochOffset =
    BigInt.parse('116444736000000000');

/// Current UTC timestamp in the same 100-nanosecond epoch used by Windows
/// process creation FILETIME values.
BigInt currentWindowsUtcFileTime() =>
    BigInt.from(DateTime.now().toUtc().microsecondsSinceEpoch) *
        BigInt.from(10) +
    _windowsFileTimeUnixEpochOffset;

/// Durable identity for the exact Mihomo process started by SSRVPN.
///
/// A PID and executable path are not sufficient because Windows can reuse a PID
/// after the original process exits. The process creation FILETIME is therefore
/// part of the ownership credential and must match before termination.
class WindowsCorePidRecord {
  const WindowsCorePidRecord({
    required this.pid,
    required this.creationTimeUtcFileTime,
    required this.canonicalExecutablePath,
  });

  static final RegExp _creationTimePattern = RegExp(r'^[1-9][0-9]{0,19}$');
  static final RegExp _drivePathPattern = RegExp(r'^[A-Za-z]:\\');
  static final RegExp _uncPathPattern = RegExp(r'^\\\\[^\\]+\\[^\\]+');
  static final RegExp _extendedDrivePathPattern =
      RegExp(r'^\\\\\?\\[A-Za-z]:\\');
  static final BigInt _maxUnsigned64 = BigInt.parse('18446744073709551615');

  final int pid;
  final String creationTimeUtcFileTime;
  final String canonicalExecutablePath;

  String encode() => '${jsonEncode(<String, Object>{
            'version': windowsCorePidRecordVersion,
            'pid': pid,
            'creationTimeUtcFileTime': creationTimeUtcFileTime,
            'canonicalExecutablePath': canonicalExecutablePath,
          })}\n';

  static WindowsCorePidRecord? tryParse(String contents) {
    if (utf8.encode(contents).length > maxWindowsCorePidRecordBytes) {
      return null;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    const expectedKeys = <String>{
      'version',
      'pid',
      'creationTimeUtcFileTime',
      'canonicalExecutablePath',
    };
    if (decoded.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(decoded.keys.toSet()).isNotEmpty) {
      return null;
    }
    if (decoded['version'] != windowsCorePidRecordVersion) return null;

    final pid = decoded['pid'];
    final creationTime = decoded['creationTimeUtcFileTime'];
    final executablePath = decoded['canonicalExecutablePath'];
    if (pid is! int || pid <= 1 || pid > 0xffffffff) return null;
    if (creationTime is! String ||
        !_creationTimePattern.hasMatch(creationTime)) {
      return null;
    }
    final creationTimeValue = BigInt.tryParse(creationTime);
    if (creationTimeValue == null || creationTimeValue > _maxUnsigned64) {
      return null;
    }
    if (executablePath is! String ||
        !_isCanonicalWindowsExecutablePath(executablePath)) {
      return null;
    }
    return WindowsCorePidRecord(
      pid: pid,
      creationTimeUtcFileTime: creationTime,
      canonicalExecutablePath: executablePath,
    );
  }

  static bool _isCanonicalWindowsExecutablePath(String path) {
    if (path.isEmpty ||
        path.length > 32767 ||
        path != path.trim() ||
        path.contains('\u0000') ||
        path.contains('\r') ||
        path.contains('\n') ||
        path.contains('/')) {
      return false;
    }
    if (!_drivePathPattern.hasMatch(path) &&
        !_uncPathPattern.hasMatch(path) &&
        !_extendedDrivePathPattern.hasMatch(path)) {
      return false;
    }
    return !path
        .split('\\')
        .any((segment) => segment == '.' || segment == '..');
  }

  bool hasSameIdentity(WindowsCorePidRecord other) =>
      pid == other.pid &&
      creationTimeUtcFileTime == other.creationTimeUtcFileTime &&
      canonicalExecutablePath.toLowerCase() ==
          other.canonicalExecutablePath.toLowerCase();

  @override
  bool operator ==(Object other) =>
      other is WindowsCorePidRecord && hasSameIdentity(other);

  @override
  int get hashCode => Object.hash(
        pid,
        creationTimeUtcFileTime,
        canonicalExecutablePath.toLowerCase(),
      );
}

/// Owns the narrow critical section between spawning Mihomo and publishing its
/// durable process identity.
///
/// Cancellation is intentionally not accepted here. Once a process exists, its
/// identity must either be captured and persisted or the exact held [Process]
/// object must remain available for confirmed cleanup.
final class WindowsCoreIdentityEstablishment {
  WindowsCoreIdentityEstablishment(
    this.process, {
    required this.spawnStartedAtUtcFileTime,
    required this.spawnReturnedAtUtcFileTime,
  })  : assert(spawnStartedAtUtcFileTime > BigInt.zero),
        assert(spawnReturnedAtUtcFileTime >= spawnStartedAtUtcFileTime),
        _processExit = process.exitCode;

  final Process process;
  final BigInt spawnStartedAtUtcFileTime;
  final BigInt spawnReturnedAtUtcFileTime;
  final Future<int> _processExit;
  WindowsCorePidRecord? _capturedIdentity;

  WindowsCorePidRecord? get capturedIdentity => _capturedIdentity;

  bool ownsProcess(Process candidate) => identical(process, candidate);

  bool ownsUnidentifiedProcess(Process candidate) =>
      _capturedIdentity == null && ownsProcess(candidate);

  Future<WindowsCorePidRecord> establish({
    required Future<WindowsCorePidRecord> Function(int pid) capture,
    required Future<void> Function(WindowsCorePidRecord identity) persist,
    required void Function() ensureStartCurrent,
  }) async {
    final identity = await _completeWhileSpawnIsAlive(
      capture(process.pid),
      phase: 'capturing its durable identity',
    );
    if (identity.pid != process.pid) {
      throw StateError('Captured Mihomo identity did not match the spawn PID');
    }
    final creationTime = BigInt.parse(identity.creationTimeUtcFileTime);
    if (creationTime < spawnStartedAtUtcFileTime ||
        creationTime > spawnReturnedAtUtcFileTime) {
      throw StateError(
        'Captured Mihomo identity was outside the exact spawn window',
      );
    }

    // Process.exitCode is bound to the original Process handle. Waiting one
    // event-loop turn after the PID-based capture lets an already-signalled
    // original exit win before a reused PID can be persisted as ours.
    await _completeWhileSpawnIsAlive(
      Future<void>.delayed(Duration.zero),
      phase: 'validating its durable identity',
    );

    await persist(identity);
    // Once persistence succeeds, retain the exact record even when the child
    // exits immediately: failed-start cleanup needs it to remove the durable
    // record without ever targeting a different PID occupant.
    _capturedIdentity = identity;
    await _completeWhileSpawnIsAlive(
      Future<void>.delayed(Duration.zero),
      phase: 'publishing its durable identity',
    );
    ensureStartCurrent();
    return identity;
  }

  Future<T> _completeWhileSpawnIsAlive<T>(
    Future<T> operation, {
    required String phase,
  }) {
    final completion = Completer<T>();

    // Register the held Process exit first. If both Futures were already
    // completed, fail closed instead of accepting a result for a recycled PID.
    _processExit.then<void>(
      (exitCode) {
        if (!completion.isCompleted) {
          completion.completeError(
            StateError(
                'Spawned Mihomo exited with code $exitCode while $phase'),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completion.isCompleted) {
          completion.completeError(
            StateError('Could not observe spawned Mihomo while $phase: $error'),
            stackTrace,
          );
        }
      },
    );
    operation.then<void>(
      (value) {
        if (!completion.isCompleted) completion.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completion.isCompleted) {
          completion.completeError(error, stackTrace);
        }
      },
    );
    return completion.future;
  }

  Future<bool> terminateUnidentifiedProcess(
    Process candidate, {
    required Future<bool> Function(Process process) terminate,
  }) async {
    if (!ownsUnidentifiedProcess(candidate)) {
      throw StateError(
        'Refused to terminate a process not owned by this unidentified spawn',
      );
    }
    return terminate(process);
  }
}
