import 'dart:io';
import 'dart:typed_data';

/// PNG decoders may inflate all IDAT bytes before consulting pixel dimensions.
/// Count streamed output first, without retaining it, including Adam7 passes.
void validateQrPngData(Uint8List bytes) {
  if (bytes.length < 8 ||
      ByteData.sublistView(bytes).getUint32(0) != 0x89504e47 ||
      ByteData.sublistView(bytes).getUint32(4) != 0x0d0a1a0a) {
    return;
  }
  const invalid = FormatException('PNG 图像数据与尺寸不符');
  if (bytes.length < 33) throw invalid;
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(8) != 13 || data.getUint32(12) != 0x49484452) {
    throw invalid;
  }
  final width = data.getUint32(16), height = data.getUint32(20);
  final depth = bytes[24];
  final channels = switch (bytes[25]) {
    0 || 3 => 1,
    2 => 3,
    4 => 2,
    6 => 4,
    _ => throw invalid,
  };
  if (![1, 2, 4, 8, 16].contains(depth) || bytes[28] > 1) throw invalid;
  final passes = bytes[28] == 0
      ? const [(0, 0, 1, 1)]
      : const [
          (0, 0, 8, 8),
          (4, 0, 8, 8),
          (0, 4, 4, 8),
          (2, 0, 4, 4),
          (0, 2, 2, 4),
          (1, 0, 2, 2),
          (0, 1, 1, 2),
        ];
  var expected = 0;
  for (final (x, y, dx, dy) in passes) {
    if (width <= x || height <= y) continue;
    final columns = (width - x + dx - 1) ~/ dx;
    final rows = (height - y + dy - 1) ~/ dy;
    expected += (((columns * channels * depth + 7) ~/ 8) + 1) * rows;
  }
  final counter = _PixelBytes(expected);
  final inflater = ZLibDecoder().startChunkedConversion(counter);
  var ended = false;
  for (var offset = 33; offset < bytes.length;) {
    if (bytes.length - offset < 12) throw invalid;
    final size = data.getUint32(offset), type = data.getUint32(offset + 4);
    final end = offset + size + 12;
    if (end > bytes.length || type == 0x49484452) throw invalid;
    if (type == 0x49444154) {
      // Feed bounded compressed chunks; output is discarded as it arrives.
      for (var start = offset + 8; start < end - 4; start += 4096) {
        final stop = start + 4096 < end - 4 ? start + 4096 : end - 4;
        inflater.add(Uint8List.sublistView(bytes, start, stop));
      }
    }
    if (type == 0x49454e44) {
      ended = true;
      break;
    }
    offset = end;
  }
  inflater.close();
  if (!ended || counter.count != expected) throw invalid;
}

class _PixelBytes implements Sink<List<int>> {
  _PixelBytes(this.limit);
  final int limit;
  int count = 0;
  @override
  void add(List<int> data) {
    count += data.length;
    if (count > limit) throw const FormatException('PNG 解压数据超出图像尺寸');
  }

  @override
  void close() {}
}
