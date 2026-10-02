import 'dart:typed_data';

/// Keep only pixel-relevant chunks after validating framing, ordering and CRCs.
/// Ancillary/animation parsers must not select a different IDAT byte stream.
Uint8List qrPngPixelStream(Uint8List bytes) {
  const invalid = FormatException('PNG 块结构无效');
  final data = ByteData.sublistView(bytes);
  final output = BytesBuilder(copy: false)..add(bytes.sublist(0, 8));
  var header = false, image = false, afterImage = false, ended = false;
  var paletteEntries = 0;
  final seen = <String>{};
  for (var offset = 8; offset < bytes.length;) {
    if (bytes.length - offset < 12) throw invalid;
    final size = data.getUint32(offset);
    final end = offset + size + 12;
    if (end > bytes.length) throw invalid;
    final typeBytes = bytes.sublist(offset + 4, offset + 8);
    if (typeBytes.any((b) => !(b >= 65 && b <= 90 || b >= 97 && b <= 122)) ||
        typeBytes[2] & 32 != 0) {
      throw invalid;
    }
    final type = String.fromCharCodes(typeBytes);
    if (_crc(Uint8List.sublistView(bytes, offset + 4, end - 4)) !=
        data.getUint32(end - 4)) {
      throw invalid;
    }
    if (!header && type != 'IHDR') throw invalid;
    final color = bytes.length > 25 ? bytes[25] : -1;
    if (type == 'IHDR') {
      if (header || size != 13) throw invalid;
      header = true;
    } else if (type == 'PLTE') {
      if (image ||
          paletteEntries != 0 ||
          size == 0 ||
          size > 768 ||
          size % 3 != 0 ||
          color == 0 ||
          color == 4) {
        throw invalid;
      }
      paletteEntries = size ~/ 3;
    } else if (type == 'tRNS') {
      if (image ||
          !seen.add(type) ||
          !(color == 0 && size == 2 ||
              color == 2 && size == 6 ||
              color == 3 && size > 0 && size <= paletteEntries)) {
        throw invalid;
      }
    } else if (type == 'IDAT') {
      if (afterImage || color == 3 && paletteEntries == 0) throw invalid;
      image = true;
    } else if (type == 'IEND') {
      if (!image || size != 0 || end != bytes.length) throw invalid;
      ended = true;
    } else {
      // These image-library parsers consume fixed/field-derived byte counts.
      final requiredSize = switch (type) {
        'acTL' => 8,
        'fcTL' => 26,
        'gAMA' || 'cICP' => 4,
        'pHYs' => 9,
        'bKGD' => color == 3 ? 1 : (color == 0 || color == 4 ? 2 : 6),
        _ => null,
      };
      if (requiredSize != null && size != requiredSize ||
          type == 'fdAT' && size < 4 ||
          typeBytes.first & 32 == 0) {
        throw invalid;
      }
      if (type == 'gAMA' && (!seen.add(type) || image)) throw invalid;
    }
    if (image && type != 'IDAT') afterImage = true;
    if (const {'IHDR', 'PLTE', 'tRNS', 'gAMA', 'IDAT', 'IEND'}.contains(type)) {
      output.add(Uint8List.sublistView(bytes, offset, end));
    }
    offset = end;
  }
  if (!ended) throw invalid;
  return output.takeBytes();
}

final _crcTable = Uint32List.fromList(List.generate(256, (value) {
  for (var bit = 0; bit < 8; bit++) {
    value = (value >> 1) ^ ((value & 1) != 0 ? 0xedb88320 : 0);
  }
  return value;
}));

int _crc(Uint8List bytes) {
  var value = 0xffffffff;
  for (final byte in bytes) {
    value = _crcTable[(value ^ byte) & 255] ^ (value >> 8);
  }
  return value ^ 0xffffffff;
}
