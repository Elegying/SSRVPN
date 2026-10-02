import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Prepare only the first animation frame, validating its encoded dimensions
/// before allocating pixels. The container canvas alone is not a safe bound.
img.WebPDecoder qrWebPFirstFrame(Uint8List bytes, img.WebPInfo canvas) {
  const invalid = FormatException('WebP 动画帧与画布尺寸不符');
  if (canvas.frames.isEmpty || bytes.length < 12) throw invalid;
  final frame = canvas.frames.first;
  if (frame.width < 1 ||
      frame.height < 1 ||
      frame.x + frame.width > canvas.width ||
      frame.y + frame.height > canvas.height) {
    throw invalid;
  }
  final data = ByteData.sublistView(bytes);
  final limit = data.getUint32(4, Endian.little) + 8;
  if (limit > bytes.length || limit < 12) throw invalid;
  for (var offset = 12; offset < limit;) {
    if (limit - offset < 8) throw invalid;
    final size = data.getUint32(offset + 4, Endian.little);
    final end = offset + 8 + size;
    final paddedEnd = end + (size & 1);
    if (paddedEnd > limit) throw invalid;
    if (data.getUint32(offset) == 0x414e4d46) {
      // ANMF
      if (size < 16) throw invalid;
      final payload = Uint8List.sublistView(bytes, offset + 24, end);
      // A standalone frame lets the image decoder inspect VP8/VP8L dimensions
      // without recursing through the animation's unchecked decodeFrame path.
      final standalone = Uint8List(12 + payload.length);
      standalone.setAll(0, bytes.sublist(0, 12));
      ByteData.sublistView(standalone)
          .setUint32(4, standalone.length - 8, Endian.little);
      standalone.setAll(12, payload);
      final decoder = img.WebPDecoder();
      final info = decoder.startDecode(standalone);
      if (info == null ||
          info.hasAnimation ||
          info.width != frame.width ||
          info.height != frame.height) {
        throw invalid;
      }
      return decoder;
    }
    offset = paddedEnd;
  }
  throw invalid;
}
