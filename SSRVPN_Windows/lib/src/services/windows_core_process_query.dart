import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'windows_core_identity_failure.dart';
import 'windows_core_pid_record.dart';
import 'windows_file_time.dart';

typedef _CompareOrdinalNative = Int32 Function(
    Pointer<Utf16>, Int32, Pointer<Utf16>, Int32, Int32);
typedef _CompareOrdinal = int Function(
    Pointer<Utf16>, int, Pointer<Utf16>, int, int);
final _compareOrdinal = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<_CompareOrdinalNative, _CompareOrdinal>(
        'CompareStringOrdinal');

final class WindowsCoreProcessSnapshot {
  const WindowsCoreProcessSnapshot({
    required this.pid,
    required this.sessionId,
    required this.currentSessionId,
    required this.creationTime,
    required this.executablePath,
  });

  final int pid;
  final int sessionId;
  final int currentSessionId;
  final BigInt creationTime;
  final String executablePath;
}

/// Reads one held process handle without spawning PowerShell or compiling C#.
/// All identity policy and the original eight-second budget remain fail-closed.
WindowsCorePidRecord queryWindowsCoreIdentity(int pid, String trustedPath,
    {WindowsCoreProcessSnapshot Function(int)? query}) {
  final watch = Stopwatch()..start();
  try {
    final snapshot =
        (query ?? (pid) => _queryNativeProcess(pid, trustedPath))(pid);
    if (watch.elapsed >= const Duration(seconds: 8)) {
      throw WindowsCoreIdentityFailure(WindowsCoreIdentityFailureKind.timeout,
          'Native identity query timed out');
    }
    if (snapshot.pid != pid ||
        snapshot.sessionId != snapshot.currentSessionId) {
      throw WindowsCoreIdentityFailure(WindowsCoreIdentityFailureKind.mismatch,
          'Process PID or Windows session did not match');
    }
    final record = WindowsCorePidRecord(
      pid: snapshot.pid,
      creationTimeUtcFileTime: snapshot.creationTime.toString(),
      canonicalExecutablePath: snapshot.executablePath,
    );
    return decodeWindowsCoreIdentity(
        ProcessResult(pid, 0, record.encode(), ''), pid, trustedPath);
  } on WindowsCoreIdentityFailure {
    rethrow;
  } catch (error) {
    throw WindowsCoreIdentityFailure(
        WindowsCoreIdentityFailureKind.execution, error);
  }
}

WindowsCoreProcessSnapshot _queryNativeProcess(
    int expectedPid, String trustedPath) {
  if (!Platform.isWindows) throw UnsupportedError('Windows APIs unavailable');
  if (trustedPath.length > 32767 || trustedPath.contains('\u0000')) {
    throw WindowsCoreIdentityFailure(WindowsCoreIdentityFailureKind.invalidData,
        'Invalid trusted image path');
  }
  final opened = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
      false,
      expectedPid);
  final handle = opened.value;
  if (handle.isNull) throw StateError('OpenProcess failed: ${opened.error}');
  Object? primaryError;
  try {
    return _snapshotFromHandle(handle, trustedPath);
  } catch (error) {
    primaryError = error;
    rethrow;
  } finally {
    final closed = CloseHandle(handle);
    if (!closed.value && primaryError == null) {
      throw StateError('CloseHandle failed: ${closed.error}');
    }
  }
}

WindowsCoreProcessSnapshot _snapshotFromHandle(
        HANDLE handle, String trustedPath) =>
    using((arena) {
      void ensureAlive() {
        final wait = WaitForSingleObject(handle, 0);
        if (wait.value != WAIT_TIMEOUT) {
          throw StateError('Process exited or its handle could not be queried');
        }
      }

      ensureAlive();
      final livePid = GetProcessId(handle);
      if (livePid.value == 0) {
        throw StateError('GetProcessId failed: ${livePid.error}');
      }
      final session = arena<Uint32>();
      final currentSession = arena<Uint32>();
      final sessionResult = ProcessIdToSessionId(livePid.value, session);
      final currentResult =
          ProcessIdToSessionId(GetCurrentProcessId(), currentSession);
      if (!sessionResult.value || !currentResult.value) {
        throw StateError('Process session query failed');
      }
      const capacity = 32768;
      final path = arena<Uint16>(capacity);
      final size = arena<Uint32>()..value = capacity;
      final image = QueryFullProcessImageName(
          handle, PROCESS_NAME_WIN32, PWSTR(path.cast()), size);
      if (!image.value || size.value == 0 || size.value >= capacity) {
        throw StateError('QueryFullProcessImageName failed: ${image.error}');
      }
      final expectedPath = trustedPath.toNativeUtf16(allocator: arena);
      // Use Windows ordinal comparison, retaining the old PowerShell policy
      // before the shared record decoder's case-insensitive comparison.
      if (_compareOrdinal(
              path.cast(), size.value, expectedPath, trustedPath.length, 1) !=
          2) {
        throw WindowsCoreIdentityFailure(
            WindowsCoreIdentityFailureKind.mismatch,
            'Native executable path did not match the trusted image');
      }
      final times = arena<FILETIME>(4);
      final timing =
          GetProcessTimes(handle, times, times + 1, times + 2, times + 3);
      if (!timing.value) {
        throw StateError('GetProcessTimes failed: ${timing.error}');
      }
      final creationTime = windowsFileTimeFromParts(
          times.ref.dwHighDateTime, times.ref.dwLowDateTime);
      final executable = path.cast<Utf16>().toDartString(length: size.value);
      ensureAlive();
      return WindowsCoreProcessSnapshot(
        pid: livePid.value,
        sessionId: session.value,
        currentSessionId: currentSession.value,
        creationTime: creationTime,
        executablePath: executable,
      );
    });

enum WindowsCoreTermination {
  terminatedOrGone,
  liveIdentityMismatch,
  wrongInstallation
}

/// Keeps the queried handle open through termination, preventing PID reuse
/// races. No shell, runtime C# compilation, or command-line path quoting.
Future<WindowsCoreTermination> terminateVerifiedWindowsCore(
    WindowsCorePidRecord record, String trustedPath) async {
  if (!Platform.isWindows) throw UnsupportedError('Windows APIs unavailable');
  if (WindowsCorePidRecord.tryParse(record.encode()) == null) {
    throw StateError('Invalid core identity');
  }
  final sameInstallation = using((arena) =>
      _compareOrdinal(
          record.canonicalExecutablePath.toNativeUtf16(allocator: arena),
          record.canonicalExecutablePath.length,
          trustedPath.toNativeUtf16(allocator: arena),
          trustedPath.length,
          1) ==
      2);
  if (!sameInstallation) return WindowsCoreTermination.wrongInstallation;
  final opened = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION |
          PROCESS_TERMINATE |
          PROCESS_SYNCHRONIZE,
      false,
      record.pid);
  final handle = opened.value;
  if (handle.isNull) {
    if (opened.error == ERROR_INVALID_PARAMETER) {
      return WindowsCoreTermination.terminatedOrGone;
    }
    throw StateError('OpenProcess failed: ${opened.error}');
  }
  try {
    if (WaitForSingleObject(handle, 0).value == WAIT_OBJECT_0) {
      return WindowsCoreTermination.terminatedOrGone;
    }
    final snapshot = _snapshotFromHandle(handle, trustedPath);
    if (snapshot.pid != record.pid ||
        snapshot.sessionId != snapshot.currentSessionId ||
        snapshot.creationTime.toString() != record.creationTimeUtcFileTime) {
      return WindowsCoreTermination.liveIdentityMismatch;
    }
    final terminated = TerminateProcess(handle, 1);
    if (!terminated.value &&
        WaitForSingleObject(handle, 0).value != WAIT_OBJECT_0) {
      throw StateError('TerminateProcess failed: ${terminated.error}');
    }
    final deadline = Stopwatch()..start();
    while (true) {
      final wait = WaitForSingleObject(handle, 0);
      if (wait.value == WAIT_OBJECT_0) {
        return WindowsCoreTermination.terminatedOrGone;
      }
      if (wait.value != WAIT_TIMEOUT) {
        throw StateError('Process wait failed: ${wait.error}');
      }
      if (deadline.elapsed >= const Duration(seconds: 8)) {
        throw TimeoutException('Core termination was not confirmed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  } on WindowsCoreIdentityFailure catch (error) {
    if (error.kind == WindowsCoreIdentityFailureKind.mismatch) {
      return WindowsCoreTermination.liveIdentityMismatch;
    }
    rethrow;
  } catch (_) {
    if (WaitForSingleObject(handle, 0).value == WAIT_OBJECT_0) {
      return WindowsCoreTermination.terminatedOrGone;
    }
    rethrow;
  } finally {
    final closed = CloseHandle(handle);
    if (!closed.value) throw StateError('CloseHandle failed: ${closed.error}');
  }
}
