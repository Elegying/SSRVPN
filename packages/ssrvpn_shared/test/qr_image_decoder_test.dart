import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ssrvpn_shared/services/qr_image_decoder.dart';
import 'qr_test_image.dart';

// Lossless 392 x 392 QR fixture encoded as WebP.
final _webpQr = base64Decode(
    'UklGRoIBAABXRUJQVlA4THYBAAAvh8FhAA8w//M///MfeJDbSJIkSaa/0k5k9jxc7u4dENH/Cei/iPZFSKlIKvt9NaVKbVQhaV4YNjNUUlIJlyaJRI/c3FoqWbq0KUkayLDNA9tfkiRJsp/Xy9ptGd+9JmUvqcZUyLwvrVIkUUQoUg7MLNJUSJQKDmwqRaJKoyHIfTE0pPJqq6r7KqooERUSlyYFpZFUNETlwBJlpoGsKUkvX5UkyUwq7YjKfT1KQWXASzkxaUxry6yUA6OpYKSSEhG9elYRRqgiyR7EeUmKViMiJdSZFSJEnkRI95VSqGhXSUWll+9qragUiVKZifsq7ZIEDVJUOi+UNYSkUNnLeWU2RImoQSq5LxVUChVPhSMraZVkqZSRujAoqMzQUNJ+X5WUNSUUVaSk8yIoTVEkSmblvJ7Fg8xEKvO87JFCqYFKkg6sKYWEiCIq0oEhFUJJkmX28oFVtEtRqRRnhqgSbVq5sakk2UhJCr16V3ullNCkiio5r/8bAg==');

Uint8List _animatedWebp(
    {int canvas = 392, int frame = 392, Uint8List? encoded}) {
  final image = encoded ?? _webpQr;
  Uint8List chunk(String type, Uint8List payload) {
    final result = Uint8List(8 + payload.length + (payload.length & 1));
    result.setAll(0, ascii.encode(type));
    ByteData.sublistView(result).setUint32(4, payload.length, Endian.little);
    result.setAll(8, payload);
    return result;
  }

  void uint24(Uint8List bytes, int offset, int value) {
    for (var i = 0; i < 3; i++) {
      bytes[offset + i] = (value >> (i * 8)) & 255;
    }
  }

  final extended = Uint8List(10)..[0] = 2;
  uint24(extended, 4, canvas - 1);
  uint24(extended, 7, canvas - 1);
  final frameData = Uint8List(16 + image.length - 12);
  uint24(frameData, 6, frame - 1);
  uint24(frameData, 9, frame - 1);
  frameData.setAll(16, image.sublist(12));
  final body = (BytesBuilder()
        ..add(ascii.encode('WEBP'))
        ..add(chunk('VP8X', extended))
        ..add(chunk('ANIM', Uint8List(6)))
        ..add(chunk('ANMF', frameData)))
      .takeBytes();
  final output = Uint8List(8 + body.length);
  output.setAll(0, ascii.encode('RIFF'));
  ByteData.sublistView(output).setUint32(4, body.length, Endian.little);
  output.setAll(8, body);
  return output;
}

void main() {
  test('PNG ancillary chunk cannot redirect the decoder to unchecked IDAT',
      () async {
    // acTL claims an oversized payload containing a second IDAT/IEND stream.
    // The old guard skipped that payload; image 4.10.1 consumed only 8 bytes.
    final input = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAO2FjVEwAAAAAAAAAAAAAAAAAAAAXSURBVHicY2AYBaNgFIyCUTAKRsGIBAAIBQABVuARbgAAAABJRU5ErkJggluyyTkAAAALSURBVHicY2AAAgAABQABel6rPwAAAABJRU5ErkJggg==');
    await expectLater(QrImageDecoder.decode(input), throwsFormatException);
  });
  test('animated WebP cannot hide frame dimensions behind a smaller canvas',
      () async {
    final input = _animatedWebp(canvas: 1, frame: 1);
    final decoder = img.WebPDecoder();
    expect(decoder.startDecode(input)!.width, 1);
    expect(decoder.decodeFrame(0)!.width, 392);
    await expectLater(QrImageDecoder.decode(input), throwsFormatException);
  });
  test('static and first animated WebP frames remain readable', () async {
    const code = 'trojan://test-password@node.example.com:443#WebP';
    expect(await QrImageDecoder.decode(_webpQr), code);
    expect(await QrImageDecoder.decode(_animatedWebp()), code);
  });
  test('WebP rejects out-of-canvas, mismatched and nested frames', () async {
    for (final input in [
      _animatedWebp(canvas: 391),
      _animatedWebp(frame: 1),
      _animatedWebp(encoded: _animatedWebp()),
    ]) {
      await expectLater(QrImageDecoder.decode(input), throwsFormatException);
    }
  });
  test('oversized encoded WebP frame is rejected before pixel allocation',
      () async {
    final encoded = Uint8List.fromList(_webpQr);
    // VP8L header: 4096 x 4096, hidden behind a 392 x 392 animation frame.
    ByteData.sublistView(encoded)
        .setUint32(21, 4095 | (4095 << 14), Endian.little);
    expect(img.WebPDecoder().startDecode(encoded)!.width, 4096);
    await expectLater(QrImageDecoder.decode(_animatedWebp(encoded: encoded)),
        throwsFormatException);
    await expectLater(QrImageDecoder.decode(encoded), throwsFormatException);
  });
  test('WebP rejects truncated and inconsistent RIFF lengths', () async {
    final input = _animatedWebp();
    final badLength = Uint8List.fromList(input);
    ByteData.sublistView(badLength).setUint32(4, 0xffffffff, Endian.little);
    await expectLater(QrImageDecoder.decode(badLength), throwsFormatException);
    // A shortened declared container must not expose its otherwise valid frame.
    ByteData.sublistView(badLength).setUint32(4, 4, Endian.little);
    await expectLater(QrImageDecoder.decode(badLength), throwsFormatException);
    final truncated = input.sublist(0, input.length - 1);
    await expectLater(QrImageDecoder.decode(truncated), throwsFormatException);
  });
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
