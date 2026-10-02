import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ssrvpn_shared/services/qr_image_decoder.dart';
import 'package:zxing2/qrcode.dart';

Uint8List qrPicture(String value, {bool invert = false}) {
  final matrix = Encoder.encode(value, ErrorCorrectionLevel.h).matrix!;
  final side = (matrix.width + 8) * 8;
  final picture = img.Image(width: side, height: side);
  for (final pixel in picture) {
    final x = pixel.x ~/ 8 - 4, y = pixel.y ~/ 8 - 4;
    final black = x >= 0 &&
        y >= 0 &&
        x < matrix.width &&
        y < matrix.height &&
        matrix.get(x, y) == 1;
    final color = black != invert ? 0 : 255;
    pixel.setRgb(color, color, color);
  }
  return img.encodePng(picture);
}

void main() {
  test('decodes normal, rotated and inverted QR images off the UI isolate',
      () async {
    const code = 'trojan://test-password@node.example.com:443#Test';
    final original = qrPicture(code);
    expect(await QrImageDecoder.decode(original), code);
    final rotated =
        img.encodePng(img.copyRotate(img.decodePng(original)!, angle: 90));
    expect(await QrImageDecoder.decode(rotated), code);
    expect(await QrImageDecoder.decode(qrPicture(code, invert: true)), code);
  });
  test('malformed images and images without QR do not yield import text',
      () async {
    expect(await QrImageDecoder.decode(Uint8List.fromList([1, 2, 3])), isNull);
    expect(
        await QrImageDecoder.decode(
            img.encodePng(img.Image(width: 80, height: 80))),
        isNull);
  });
  test('oversized byte payload is rejected before decoding', () async {
    await expectLater(
        QrImageDecoder.decode(Uint8List(QrImageDecoder.maxBytes + 1)),
        throwsFormatException);
  });
}
