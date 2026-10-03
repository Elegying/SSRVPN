import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/src/services/windows_file_time.dart';

void main() {
  test('FILETIME preserves creation digits lost by a DateTime round trip', () {
    final expected = BigInt.parse('134145678901234567');
    final mask = BigInt.from(0xffffffff);
    final actual = windowsFileTimeFromParts(
        (expected >> 32).toInt(), (expected & mask).toInt());
    expect(actual, expected);
    expect(actual % BigInt.from(10), BigInt.from(7));
    // A spawn returned at this value must include a creation at the same
    // native timestamp. Microsecond truncation used to reject it by 700 ns.
    expect(actual, greaterThan(actual ~/ BigInt.from(10) * BigInt.from(10)));
  });

  test('FILETIME combination retains unsigned high bits and the full range',
      () {
    expect(windowsFileTimeFromParts(0x80000000, 1),
        BigInt.parse('9223372036854775809'));
    expect(windowsFileTimeFromParts(0xffffffff, 0xffffffff),
        BigInt.parse('18446744073709551615'));
  });
}
