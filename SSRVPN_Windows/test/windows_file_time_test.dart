import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/src/services/windows_file_time.dart';
import 'package:win32/win32.dart';

void main() {
  test(
    'native creation time remains inside the unmodified spawn clock window',
    () {
      for (var attempt = 0; attempt < 256; attempt++) {
        using((arena) {
          final executable = Platform.resolvedExecutable.toNativeUtf16(
            allocator: arena,
          );
          final startup = arena<STARTUPINFO>()..ref.cb = sizeOf<STARTUPINFO>();
          final process = arena<PROCESS_INFORMATION>();
          final before = currentWindowsUtcFileTime();
          final created = CreateProcess(
            PCWSTR(executable),
            null,
            null,
            null,
            false,
            CREATE_SUSPENDED | CREATE_NO_WINDOW,
            null,
            null,
            startup,
            process,
          );
          final after = currentWindowsUtcFileTime();
          expect(
            created.value,
            isTrue,
            reason: 'CreateProcess: ${created.error}',
          );
          try {
            final times = arena<FILETIME>(4);
            final queried = GetProcessTimes(
              process.ref.hProcess,
              times,
              times + 1,
              times + 2,
              times + 3,
            );
            expect(
              queried.value,
              isTrue,
              reason: 'GetProcessTimes: ${queried.error}',
            );
            final creation = windowsFileTimeFromParts(
              times.ref.dwHighDateTime,
              times.ref.dwLowDateTime,
            );
            expect(
              creation,
              allOf(greaterThanOrEqualTo(before), lessThanOrEqualTo(after)),
              reason:
                  'attempt=$attempt before=$before creation=$creation after=$after',
            );
          } finally {
            // Never resume the fixture or target a PID/name: only release the
            // exact suspended process and thread handles created above.
            try {
              expect(TerminateProcess(process.ref.hProcess, 0).value, isTrue);
              expect(
                WaitForSingleObject(process.ref.hProcess, 5000).value,
                WAIT_OBJECT_0,
              );
            } finally {
              CloseHandle(process.ref.hThread);
              CloseHandle(process.ref.hProcess);
            }
          }
        });
      }
    },
    skip: !Platform.isWindows,
  );

  test('FILETIME preserves creation digits lost by a DateTime round trip', () {
    final expected = BigInt.parse('134145678901234567');
    final mask = BigInt.from(0xffffffff);
    final actual = windowsFileTimeFromParts(
      (expected >> 32).toInt(),
      (expected & mask).toInt(),
    );
    expect(actual, expected);
    expect(actual % BigInt.from(10), BigInt.from(7));
    // A spawn returned at this value must include a creation at the same
    // native timestamp. Microsecond truncation used to reject it by 700 ns.
    expect(actual, greaterThan(actual ~/ BigInt.from(10) * BigInt.from(10)));
  });

  test(
    'FILETIME combination retains unsigned high bits and the full range',
    () {
      expect(
        windowsFileTimeFromParts(0x80000000, 1),
        BigInt.parse('9223372036854775809'),
      );
      expect(
        windowsFileTimeFromParts(0xffffffff, 0xffffffff),
        BigInt.parse('18446744073709551615'),
      );
    },
  );
}
