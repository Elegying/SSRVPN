import 'dart:typed_data';

/// image's JPEG startDecode allocates DCT blocks while reading SOF, before it
/// returns dimensions. Validate the first frame without invoking that decoder.
void validateQrJpegData(Uint8List bytes, {int maxPixels = 16000000}) {
  const invalid = FormatException('JPEG 图像尺寸或帧结构无效');
  if (bytes.length < 2 || bytes[0] != 0xff || bytes[1] != 0xd8) {
    throw invalid;
  }
  final data = ByteData.sublistView(bytes);
  var frame = false;
  for (var offset = 2; offset < bytes.length;) {
    if (bytes[offset++] != 0xff) throw invalid;
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) throw invalid;
    final marker = bytes[offset++];
    if (bytes.length - offset < 2) throw invalid;
    final length = data.getUint16(offset);
    final end = offset + length;
    if (length < 2 || end > bytes.length) throw invalid;
    final payload = offset + 2;
    if (marker == 0xc0 || marker == 0xc1 || marker == 0xc2) {
      if (frame || length < 8) throw invalid;
      final height = data.getUint16(payload + 1);
      final width = data.getUint16(payload + 3);
      final count = bytes[payload + 5];
      if (bytes[payload] != 8 ||
          width < 1 ||
          height < 1 ||
          width * height > maxPixels ||
          !const [1, 3, 4].contains(count) ||
          length != 8 + 3 * count) {
        throw invalid;
      }
      final ids = <int>{};
      var maxH = 0, maxV = 0, blocksPerMcu = 0;
      for (var i = 0; i < count; i++) {
        final component = payload + 6 + i * 3;
        final sampling = bytes[component + 1];
        final h = sampling >> 4, v = sampling & 15;
        if (!ids.add(bytes[component]) ||
            h < 1 ||
            h > 4 ||
            v < 1 ||
            v > 4 ||
            bytes[component + 2] > 3) throw invalid;
        if (h > maxH) maxH = h;
        if (v > maxV) maxV = v;
        blocksPerMcu += h * v;
      }
      // Bound padded DCT Int32 blocks as well as final pixels (128 MiB).
      final columns = (width + 8 * maxH - 1) ~/ (8 * maxH);
      final rows = (height + 8 * maxV - 1) ~/ (8 * maxV);
      if (blocksPerMcu > 10 ||
          columns * rows * blocksPerMcu * 64 * 4 > 128 * 1024 * 1024) {
        throw invalid;
      }
      frame = true;
    } else if (marker == 0xda) {
      if (!frame) throw invalid;
      // Later SOFs are rejected by image as duplicates before allocation.
      return;
    } else if (!(marker >= 0xe0 && marker <= 0xef ||
        const [0xc4, 0xdb, 0xdd, 0xfe].contains(marker))) {
      throw invalid;
    }
    offset = end;
  }
  throw invalid;
}
