import 'dart:typed_data';
import 'package:image/image.dart' as img;
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
