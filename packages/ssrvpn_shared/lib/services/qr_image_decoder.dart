import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import 'qr_png_guard.dart';
import 'qr_webp_frame.dart';

class QrImageDecoder {
  static const maxBytes = 12 * 1024 * 1024;
  static const maxPixels = 16000000;
  static Future<String?> read(XFile file) async {
    if (await file.length() > maxBytes) {
      throw const FormatException('图片过大，请裁剪二维码后重试');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('图片过大');
      }
      bytes.add(chunk);
    }
    return decode(bytes.takeBytes());
  }

  static Future<String?> decode(Uint8List bytes) async {
    if (bytes.length > maxBytes) throw const FormatException('图片过大');
    final port = ReceivePort();
    Isolate? worker;
    try {
      worker = await Isolate.spawn(_decode, (port.sendPort, bytes));
      final value = await port.first.timeout(const Duration(seconds: 8));
      if (value is String) return value;
      if (value == false) throw const FormatException('图片无效或分辨率过大，请裁剪后重试');
      return null;
    } finally {
      worker?.kill(priority: Isolate.immediate);
      port.close();
    }
  }

  static void _decode((SendPort, Uint8List) input) {
    final (send, sourceBytes) = input;
    try {
      final bytes = validateQrPngData(sourceBytes, maxPixels: maxPixels);
      // Reject oversized headers before allocating the decoded pixel buffer.
      var decoder = img.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info == null ||
          info.width < 1 ||
          info.height < 1 ||
          info.width * info.height > maxPixels) {
        send.send(false);
        return;
      }
      if (decoder is img.WebPDecoder &&
          info is img.WebPInfo &&
          info.hasAnimation) {
        decoder = qrWebPFirstFrame(bytes, info);
      }
      var picture = decoder!.decodeFrame(0);
      if (picture == null) {
        send.send(false);
        return;
      }
      picture = img.bakeOrientation(picture);
      if (picture.width > 1600 || picture.height > 1600) {
        picture = img.copyResize(
          picture,
          width: picture.width >= picture.height ? 1600 : null,
          height: picture.height > picture.width ? 1600 : null,
        );
      }
      final pixels = Int32List(picture.width * picture.height);
      for (final pixel in picture) {
        // Gallery PNGs may use transparent backgrounds or 16-bit channels.
        // Render against white and normalize before supplying 8-bit RGB.
        final opacity = pixel.aNormalized * 255;
        final background = 255 - opacity;
        final red = (pixel.rNormalized * opacity + background).round();
        final green = (pixel.gNormalized * opacity + background).round();
        final blue = (pixel.bNormalized * opacity + background).round();
        pixels[pixel.y * picture.width + pixel.x] =
            (red << 16) | (green << 8) | blue;
      }
      final source = RGBLuminanceSource(picture.width, picture.height, pixels);
      final reader = QRCodeReader();
      String? result;
      try {
        result = reader.decode(BinaryBitmap(HybridBinarizer(source))).text;
      } catch (_) {
        result =
            reader.decode(BinaryBitmap(HybridBinarizer(source.invert()))).text;
      }
      send.send(result.length <= 16384 ? result : null);
    } on FormatException {
      send.send(false);
    } catch (_) {
      send.send(null);
    }
  }
}
