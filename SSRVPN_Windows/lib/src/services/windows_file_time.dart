import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'windows_core_identity_failure.dart';

final class _FileTime extends Struct {
  @Uint32()
  external int low;

  @Uint32()
  external int high;
}

typedef _ReadFileTimeNative = Void Function(Pointer<_FileTime>);
typedef _ReadFileTime = void Function(Pointer<_FileTime>);

final _ReadFileTime? _readFileTime = Platform.isWindows
    ? DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_ReadFileTimeNative, _ReadFileTime>(
            'GetSystemTimePreciseAsFileTime')
    : null;

BigInt windowsFileTimeFromParts(int high, int low) =>
    (BigInt.from(high) << 32) | BigInt.from(low);

/// Reads precise Windows UTC without truncating the native 100-ns digits.
/// GetSystemTimeAsFileTime can lag a newly created process even though it also
/// returns FILETIME. Its coarse tick must not define the strict spawn window.
BigInt currentWindowsUtcFileTime() {
  final read = _readFileTime;
  if (read == null) {
    return BigInt.from(DateTime.now().toUtc().microsecondsSinceEpoch) *
            BigInt.from(10) +
        BigInt.parse('116444736000000000');
  }
  final time = calloc<_FileTime>();
  try {
    read(time);
    final value = windowsFileTimeFromParts(time.ref.high, time.ref.low);
    if (value <= BigInt.zero) {
      throw WindowsCoreIdentityFailure(WindowsCoreIdentityFailureKind.execution,
          'Windows returned an invalid native FILETIME');
    }
    return value;
  } finally {
    calloc.free(time);
  }
}
