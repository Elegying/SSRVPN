import 'dart:convert';
import 'dart:io';
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
  test('PNG data cannot inflate beyond the declared pixel dimensions',
      () async {
    const code = 'trojan://test-password@node.example.com:443#Bounded';
    final original = qrPicture(code);
    final compressed = BytesBuilder();
    final kept = BytesBuilder()..add(original.sublist(0, 8));
    for (var offset = 8; offset < original.length;) {
      final size = ByteData.sublistView(original, offset).getUint32(0);
      final type = ascii.decode(original.sublist(offset + 4, offset + 8));
      if (type == 'IDAT') {
        compressed.add(original.sublist(offset + 8, offset + 8 + size));
      } else if (type != 'IEND') {
        kept.add(original.sublist(offset, offset + size + 12));
      }
      offset += size + 12;
    }
    final expanded = BytesBuilder()
      ..add(zlib.decode(compressed.takeBytes()))
      ..add(Uint8List(2 * 1024 * 1024));
    final payload = zlib.encode(expanded.takeBytes());
    final chunk = Uint8List(payload.length + 12);
    ByteData.sublistView(chunk).setUint32(0, payload.length);
    chunk.setAll(4, ascii.encode('IDAT'));
    chunk.setAll(8, payload);
    var crc = 0xffffffff;
    for (final byte in chunk.sublist(4, chunk.length - 4)) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
      }
    }
    ByteData.sublistView(chunk).setUint32(chunk.length - 4, crc ^ 0xffffffff);
    kept
      ..add(chunk)
      ..add(original.sublist(original.length - 12));
    await expectLater(
        QrImageDecoder.decode(kept.takeBytes()), throwsFormatException);
  });
  test('oversized dimensions are rejected from a valid PNG header', () async {
    // 50,000 x 50,000 RGB pixels; valid IHDR CRC, no pixel allocation needed.
    final header = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAw1AAAMNQCAIAAADEzaqdAAAAAElFTkSuQmCC');
    await expectLater(QrImageDecoder.decode(header), throwsFormatException);
  });
  test('decodes 16-bit PNG channels without overflowing RGB values', () async {
    const code = 'trojan://test-password@node.example.com:443#16bit';
    final picture =
        img.decodePng(qrPicture(code))!.convert(format: img.Format.uint16);
    expect(await QrImageDecoder.decode(img.encodePng(picture)), code);
  });
  test('decodes a QR with transparent background from the gallery', () async {
    const code = 'trojan://test-password@node.example.com:443#Transparent';
    final opaque = img.decodePng(qrPicture(code))!;
    final transparent =
        img.Image(width: opaque.width, height: opaque.height, numChannels: 4);
    for (final pixel in transparent) {
      final black = opaque.getPixel(pixel.x, pixel.y).r == 0;
      pixel.setRgba(0, 0, 0, black ? 255 : 0);
    }
    expect(await QrImageDecoder.decode(img.encodePng(transparent)), code);
  });
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
