part of 'node_country_lookup.dart';

_MmdbCountryReader _decodeCountryDatabase(Uint8List compressed) {
  if (compressed.length > 8 * 1024 * 1024) {
    throw const FormatException('Country database archive is too large');
  }
  final output = _BoundedDatabaseBytes();
  final decoder = gzip.decoder.startChunkedConversion(output);
  decoder.add(compressed);
  decoder.close();
  return _MmdbCountryReader(output.bytes.takeBytes());
}

class _BoundedDatabaseBytes implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > 32 * 1024 * 1024) {
      throw const FormatException('Country database is too large');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}

class _MmdbCountryReader {
  _MmdbCountryReader(this._bytes) {
    final metadataStart = _metadataStart();
    if (metadataStart < 0) {
      throw const FormatException('Missing MaxMind metadata.');
    }

    final decoder = _MmdbDecoder(_bytes, baseOffset: metadataStart);
    final result = decoder.decode(metadataStart);
    final metadata = result.value;
    if (metadata is! Map) {
      throw const FormatException('Invalid MaxMind metadata.');
    }

    _nodeCount = _readInt(metadata['node_count']);
    _recordSize = _readInt(metadata['record_size']);
    _ipVersion = _readInt(metadata['ip_version']);
    if (_nodeCount <= 0 ||
        !const [24, 28, 32].contains(_recordSize) ||
        !const [4, 6].contains(_ipVersion)) {
      throw const FormatException('Invalid MaxMind tree metadata');
    }
    _nodeByteSize = _recordSize ~/ 4;
    _searchTreeSize = _nodeCount * _nodeByteSize;
    if (_searchTreeSize + 16 >= metadataStart - _metadataMarker.length ||
        _bytes
            .sublist(_searchTreeSize, _searchTreeSize + 16)
            .any((b) => b != 0)) {
      throw const FormatException('Invalid MaxMind tree boundary');
    }
    // Data pointers are relative to the data section after the 16-byte
    // separator: https://maxmind.github.io/MaxMind-DB/#pointer---1
    _dataDecoder = _MmdbDecoder(_bytes,
        baseOffset: _searchTreeSize + 16,
        endOffset: metadataStart - _metadataMarker.length);
    _ipv4StartNode = _ipVersion == 6 ? _resolveIpv4StartNode() : 0;
  }

  static const List<int> _metadataMarker = [
    0xab,
    0xcd,
    0xef,
    77,
    97,
    120,
    77,
    105,
    110,
    100,
    46,
    99,
    111,
    109,
  ];

  final Uint8List _bytes;
  late final int _nodeCount;
  late final int _recordSize;
  late final int _ipVersion;
  late final int _nodeByteSize;
  late final int _searchTreeSize;
  late final int _ipv4StartNode;
  late final _MmdbDecoder _dataDecoder;

  String? countryCodeForIp(String ip) {
    final address = InternetAddress.tryParse(ip);
    if (address == null) return null;
    if (_ipVersion == 4 && address.type == InternetAddressType.IPv6) {
      return null;
    }

    var node = address.type == InternetAddressType.IPv4 && _ipVersion == 6
        ? _ipv4StartNode
        : 0;
    final bitCount = address.type == InternetAddressType.IPv4 ? 32 : 128;
    final raw = address.rawAddress;

    if (node > _nodeCount) return _countryAtPointer(node);
    for (var i = 0; i < bitCount; i++) {
      final bit = (raw[i >> 3] >> (7 - (i & 7))) & 1;
      node = _readNode(node, bit);
      if (node == _nodeCount) return null;
      if (node > _nodeCount) {
        return _countryAtPointer(node);
      }
    }

    return null;
  }

  String? _countryAtPointer(int node) {
    final offset = node - _nodeCount + _searchTreeSize;
    if (offset < _searchTreeSize + 16) return null;
    return _extractCountryCode(_dataDecoder.decode(offset).value);
  }

  int _metadataStart() {
    final minimum = _bytes.length > 128 * 1024 ? _bytes.length - 128 * 1024 : 0;
    for (var i = _bytes.length - _metadataMarker.length; i >= minimum; i--) {
      var matches = true;
      for (var j = 0; j < _metadataMarker.length; j++) {
        if (_bytes[i + j] != _metadataMarker[j]) {
          matches = false;
          break;
        }
      }
      if (matches) return i + _metadataMarker.length;
    }
    return -1;
  }

  int _resolveIpv4StartNode() {
    var node = 0;
    for (var i = 0; i < 96 && node < _nodeCount; i++) {
      node = _readNode(node, 0);
    }
    return node;
  }

  int _readNode(int nodeNumber, int index) {
    final offset = nodeNumber * _nodeByteSize;
    if (offset < 0 || offset + _nodeByteSize > _searchTreeSize) {
      return _nodeCount;
    }

    if (_recordSize == 24) {
      final left = _uint24(offset);
      final right = _uint24(offset + 3);
      return index == 0 ? left : right;
    }

    if (_recordSize == 28) {
      final middle = _bytes[offset + 3];
      final left = ((middle >> 4) << 24) | _uint24(offset);
      final right = ((middle & 0x0f) << 24) | _uint24(offset + 4);
      return index == 0 ? left : right;
    }

    if (_recordSize == 32) {
      final left = _uint32(offset);
      final right = _uint32(offset + 4);
      return index == 0 ? left : right;
    }

    return _nodeCount;
  }

  int _uint24(int offset) {
    return (_bytes[offset] << 16) |
        (_bytes[offset + 1] << 8) |
        _bytes[offset + 2];
  }

  int _uint32(int offset) {
    return (_bytes[offset] << 24) |
        (_bytes[offset + 1] << 16) |
        (_bytes[offset + 2] << 8) |
        _bytes[offset + 3];
  }

  int _readInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String? _extractCountryCode(Object? value) {
    if (value is String) return _validCountryCode(value);

    if (value is Map) {
      final direct = _validCountryCode(value['iso_code']?.toString()) ??
          _validCountryCode(value['country_code']?.toString()) ??
          _validCountryCode(value['code']?.toString());
      if (direct != null) return direct;

      const nestedKeys = [
        'country',
        'registered_country',
        'represented_country',
        'traits',
      ];
      for (final key in nestedKeys) {
        final nested = _extractCountryCode(value[key]);
        if (nested != null) return nested;
      }
    }

    if (value is List) {
      for (final nested in value) {
        final result = _extractCountryCode(nested);
        if (result != null) return result;
      }
    }

    return null;
  }

  String? _validCountryCode(String? value) {
    final code = normalizeNodeCountryCode(value ?? '');
    return code == 'UN' ? null : code;
  }
}

class _MmdbDecoder {
  const _MmdbDecoder(this._bytes, {required this.baseOffset, this.endOffset});

  final Uint8List _bytes;
  final int baseOffset;
  final int? endOffset;

  _MmdbValue decode(int offset) => _decode(offset, 0, _MmdbBudget());

  _MmdbValue _decode(int offset, int depth, _MmdbBudget budget) {
    if (depth > 32 || --budget.values < 0) {
      throw const FormatException('MaxMind decode work limit');
    }
    final header = _readHeader(offset);
    var cursor = header.offset;

    switch (header.type) {
      case 1:
        final pointerOffset = baseOffset + header.pointer;
        if (_readHeader(pointerOffset).type == 1) {
          throw const FormatException('MaxMind pointer to pointer');
        }
        final pointed = _decode(pointerOffset, depth + 1, budget);
        return _MmdbValue(pointed.value, cursor);
      case 2:
        final end = cursor + header.size;
        _requirePayload(cursor, header.size, budget);
        return _MmdbValue(utf8.decode(_bytes.sublist(cursor, end)), end);
      case 3:
        final end = cursor + header.size;
        _require(cursor, header.size);
        return _MmdbValue(null, end);
      case 4:
        final end = cursor + header.size;
        _requirePayload(cursor, header.size, budget);
        return _MmdbValue(_bytes.sublist(cursor, end), end);
      case 5:
      case 6:
      case 8:
      case 9:
      case 10:
        var value = 0;
        final end = cursor + header.size;
        if (header.size > 16) {
          throw const FormatException('MaxMind integer size');
        }
        _require(cursor, header.size);
        while (cursor < end) {
          value = (value << 8) | _bytes[cursor];
          cursor++;
        }
        return _MmdbValue(value, cursor);
      case 7:
        if (header.size * 2 > budget.values) {
          throw const FormatException('MaxMind map size');
        }
        final map = <String, Object?>{};
        for (var i = 0; i < header.size; i++) {
          final key = _decode(cursor, depth + 1, budget);
          cursor = key.offset;
          final value = _decode(cursor, depth + 1, budget);
          cursor = value.offset;
          if (key.value is! String) {
            throw const FormatException('MaxMind map key');
          }
          map[key.value as String] = value.value;
        }
        return _MmdbValue(map, cursor);
      case 11:
        if (header.size > budget.values) {
          throw const FormatException('MaxMind array size');
        }
        final list = <Object?>[];
        for (var i = 0; i < header.size; i++) {
          final item = _decode(cursor, depth + 1, budget);
          cursor = item.offset;
          list.add(item.value);
        }
        return _MmdbValue(list, cursor);
      case 14:
        return _MmdbValue(header.size != 0, cursor);
      case 15:
        final end = cursor + header.size;
        _require(cursor, header.size);
        return _MmdbValue(null, end);
      default:
        throw const FormatException('Unsupported MaxMind value');
    }
  }

  void _require(int offset, int length) {
    if (offset < baseOffset ||
        length < 0 ||
        offset + length > (endOffset ?? _bytes.length)) {
      throw const FormatException('MaxMind value out of bounds');
    }
  }

  void _requirePayload(int offset, int length, _MmdbBudget budget) {
    _require(offset, length);
    budget.bytes -= length;
    if (budget.bytes < 0) throw const FormatException('MaxMind payload limit');
  }

  _MmdbHeader _readHeader(int offset) {
    _require(offset, 1);
    final control = _bytes[offset];
    var cursor = offset + 1;
    var type = control >> 5;
    var size = control & 0x1f;
    var pointer = 0;

    if (type == 0) {
      _require(cursor, 1);
      type = _bytes[cursor] + 7;
      cursor++;
    }

    if (type == 1) {
      final pointerSize = ((control >> 3) & 0x03) + 1;
      _require(cursor, pointerSize);
      pointer = pointerSize == 4 ? 0 : control & 0x07;
      for (var i = 0; i < pointerSize; i++) {
        pointer = (pointer << 8) | _bytes[cursor];
        cursor++;
      }
      const pointerBases = [0, 2048, 526336, 0];
      pointer += pointerBases[pointerSize - 1];
      return _MmdbHeader(
        type: type,
        size: 0,
        offset: cursor,
        pointer: pointer,
      );
    }

    if (size == 29) {
      _require(cursor, 1);
      size = 29 + _bytes[cursor];
      cursor++;
    } else if (size == 30) {
      _require(cursor, 2);
      size = 285 + ((_bytes[cursor] << 8) | _bytes[cursor + 1]);
      cursor += 2;
    } else if (size == 31) {
      _require(cursor, 3);
      size = 65821 +
          ((_bytes[cursor] << 16) |
              (_bytes[cursor + 1] << 8) |
              _bytes[cursor + 2]);
      cursor += 3;
    }

    return _MmdbHeader(
      type: type,
      size: size,
      offset: cursor,
      pointer: pointer,
    );
  }
}

class _MmdbBudget {
  int values = 4096;
  int bytes = 256 * 1024;
}

class _MmdbHeader {
  const _MmdbHeader({
    required this.type,
    required this.size,
    required this.offset,
    required this.pointer,
  });

  final int type;
  final int size;
  final int offset;
  final int pointer;
}

class _MmdbValue {
  const _MmdbValue(this.value, this.offset);

  final Object? value;
  final int offset;
}
