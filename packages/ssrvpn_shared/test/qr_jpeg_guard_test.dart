import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ssrvpn_shared/services/qr_image_decoder.dart';
import 'package:ssrvpn_shared/services/qr_jpeg_guard.dart';
import 'qr_test_image.dart';

Uint8List header(
        {int width = 32,
        int height = 32,
        int sampling = 0x11,
        int count = 1,
        int precision = 8}) =>
    Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      0xc0,
      0,
      8 + count * 3,
      precision,
      height >> 8,
      height & 255,
      width >> 8,
      width & 255,
      count,
      for (var i = 0; i < count; i++) ...[i + 1, sampling, 0],
      0xff,
      0xda,
      0,
      2,
      0xff,
      0xd9,
    ]);

void main() {
  test('rejects oversized SOF before entering the allocating JPEG reader', () {
    // Only the constant-space guard sees these dimensions; never decode them.
    for (final input in [
      header(width: 65535, height: 65535),
      header(width: 4096, height: 4096),
      header(width: 0),
      header(height: 0)
    ]) {
      expect(() => validateQrJpegData(input), throwsFormatException);
    }
    validateQrJpegData(header(width: 4000, height: 4000));
  });
  test('bounds padded blocks and rejects unsupported component parameters', () {
    for (final input in [
      header(sampling: 0),
      header(sampling: 0xf1),
      header(count: 2),
      header(precision: 16),
      header(sampling: 0x44),
      header(width: 4000, height: 4000, count: 3)
    ]) {
      expect(() => validateQrJpegData(input), throwsFormatException);
    }
    final duplicateId = header(count: 3)..[18] = 1;
    expect(() => validateQrJpegData(duplicateId), throwsFormatException);
  });
  test('baseline, extended and progressive SOFs share the same guarded layout',
      () {
    for (final marker in [0xc0, 0xc1, 0xc2]) {
      final input = header()..[3] = marker;
      validateQrJpegData(input);
      final metadata = Uint8List.fromList([
        255,
        216,
        255,
        225,
        0,
        6,
        255,
        192,
        255,
        255,
        ...input.sublist(2),
      ]);
      validateQrJpegData(
          metadata); // Marker-shaped metadata is not another SOF.
    }
  });
  test('malformed framing cannot hide an unchecked SOF', () {
    final valid = header();
    final badLength = Uint8List.fromList(valid)..[5] = 2;
    final duplicate =
        Uint8List.fromList([...valid.sublist(0, 15), ...valid.sublist(2)]);
    for (final input in [
      badLength,
      duplicate,
      valid.sublist(0, 12),
      Uint8List.fromList([0xff, 0xd8, 0xff, 0xda, 0, 2]),
      Uint8List.fromList([0xff, 0xd8, 0, ...valid.sublist(2)])
    ]) {
      expect(() => validateQrJpegData(input), throwsFormatException);
    }
  });
  test(
      'public decoder rejects unsafe JPEG parameters and accepts normal JPEG QR',
      () async {
    await expectLater(
        QrImageDecoder.decode(header(sampling: 0)), throwsFormatException);
    const code = 'trojan://test-password@node.example.com:443#JPEG';
    final jpeg = img.encodeJpg(img.decodePng(qrPicture(code))!, quality: 95);
    validateQrJpegData(jpeg);
    expect(await QrImageDecoder.decode(jpeg), code);
  });
  test('non-supported image formats do not enter additional decoders',
      () async {
    final gif = img.encodeGif(img.decodePng(qrPicture('ignored'))!);
    expect(await QrImageDecoder.decode(gif), isNull);
  });
}
