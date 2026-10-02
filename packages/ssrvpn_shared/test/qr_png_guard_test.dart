import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/qr_png_guard.dart';

Uint8List _chunk(String type, List<int> payload) {
  final bytes = Uint8List(payload.length + 12);
  ByteData.sublistView(bytes).setUint32(0, payload.length);
  bytes.setAll(4, ascii.encode(type));
  bytes.setAll(8, payload);
  // This guard counts bytes; CRC remains the image decoder's responsibility.
  return bytes;
}

Uint8List _png(int side, int inflated,
    {int depth = 8,
    int color = 6,
    bool interlaced = false,
    bool duplicateHeader = false}) {
  final header = Uint8List(13);
  ByteData.sublistView(header)
    ..setUint32(0, side)
    ..setUint32(4, side);
  header[8] = depth;
  header[9] = color;
  header[12] = interlaced ? 1 : 0;
  final compressed = zlib.encode(Uint8List(inflated));
  return (BytesBuilder()
        ..add([137, 80, 78, 71, 13, 10, 26, 10])
        ..add(_chunk('IHDR', header))
        ..add(duplicateHeader ? _chunk('IHDR', header) : [])
        ..add(_chunk('IDAT', compressed.sublist(0, 2)))
        ..add(_chunk('IDAT', compressed.sublist(2)))
        ..add(_chunk('IEND', [])))
      .takeBytes();
}

void main() {
  test('normal, packed and Adam7 rows accept exact sizes across IDAT chunks',
      () {
    validateQrPngData(_png(9, 333)); // 9 rows of 36 bytes plus a filter byte.
    validateQrPngData(_png(9, 27, depth: 1, color: 0));
    validateQrPngData(
        _png(9, 343, interlaced: true)); // 324 pixels + 19 filters.
    validateQrPngData(
        _png(1, 5, interlaced: true)); // Empty passes add no rows.
  });
  test('short and excess inflated data are rejected for each row layout', () {
    for (final interlaced in [false, true]) {
      final expected = interlaced ? 343 : 333;
      for (final length in [expected - 1, expected + 1, 2 * 1024 * 1024]) {
        expect(() => validateQrPngData(_png(9, length, interlaced: interlaced)),
            throwsFormatException);
      }
    }
  });
  test('ambiguous headers and truncated chunks cannot bypass the guard', () {
    expect(() => validateQrPngData(_png(9, 333, duplicateHeader: true)),
        throwsFormatException);
    final valid = _png(9, 333);
    expect(() => validateQrPngData(valid.sublist(0, valid.length - 5)),
        throwsFormatException);
    final badLength = Uint8List.fromList(valid);
    ByteData.sublistView(badLength).setUint32(33, 0xffffffff);
    expect(() => validateQrPngData(badLength), throwsFormatException);
  });
}
