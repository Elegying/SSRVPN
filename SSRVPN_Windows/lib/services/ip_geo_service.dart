import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';

import 'clash_service.dart';

class IpGeoService {
  IpGeoService._();

  static final IpGeoService instance = IpGeoService._();

  final Map<String, String> _countryCache = {};
  final Map<String, String> _exitCountryCache = {};
  final Map<String, String> _ipCache = {};
  final Map<String, Future<String>> _pendingCountry = {};
  final Map<String, Future<String>> _pendingExitCountry = {};
  Future<_MmdbCountryReader?>? _readerFuture;

  String? cachedCountryForNode(ProxyNode node) {
    return _exitCountryCache[_nodeKey(node)];
  }

  Future<String> countryCodeForNode(
    ProxyNode node,
    ClashService clashService, {
    required bool connected,
  }) {
    final key = _nodeKey(node);
    if (key.isEmpty) return Future.value('UN');

    final cached = _exitCountryCache[key];
    if (cached != null) return Future.value(cached);
    if (!connected || !clashService.isRunning) return Future.value('UN');

    return _pendingExitCountry.putIfAbsent(key, () async {
      try {
        final country = await clashService.detectExitCountryForProxy(node.name);
        final normalized = _normalizeCountry(country);
        if (normalized == 'UN') return 'UN';
        return _rememberExit(key, normalized);
      } catch (_) {
        return 'UN';
      } finally {
        _pendingExitCountry.remove(key);
      }
    });
  }

  String? cachedCountryForHost(String host) {
    final key = _hostKey(host);
    if (key.isEmpty) return null;
    return _countryCache[key];
  }

  Future<String> countryCodeForHost(String host) {
    final key = _hostKey(host);
    if (key.isEmpty) return Future.value('UN');

    final cached = _countryCache[key];
    if (cached != null) return Future.value(cached);

    return _pendingCountry.putIfAbsent(key, () async {
      try {
        final ip = await _resolveIp(key);
        if (ip == null || _isPrivateAddress(ip)) return _remember(key, 'UN');

        final reader = await _loadReader();
        final country = reader?.countryCodeForIp(ip);
        return _remember(key, _normalizeCountry(country));
      } catch (_) {
        return _remember(key, 'UN');
      } finally {
        _pendingCountry.remove(key);
      }
    });
  }

  String _remember(String host, String country) {
    final normalized = _normalizeCountry(country);
    _countryCache[host] = normalized;
    return normalized;
  }

  String _rememberExit(String key, String country) {
    final normalized = _normalizeCountry(country);
    _exitCountryCache[key] = normalized;
    return normalized;
  }

  String _nodeKey(ProxyNode node) {
    final name = node.name.trim();
    final server = node.server.trim();
    if (name.isEmpty && server.isEmpty) return '';
    return '$name|$server|${node.port}';
  }

  Future<String?> _resolveIp(String host) async {
    final cached = _ipCache[host];
    if (cached != null) return cached;

    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) {
      _ipCache[host] = parsed.address;
      return parsed.address;
    }

    final addresses = await InternetAddress.lookup(host)
        .timeout(const Duration(milliseconds: 2600));
    if (addresses.isEmpty) return null;

    final preferred = addresses
        .where((address) =>
            address.type == InternetAddressType.IPv4 &&
            !_isPrivateAddress(address.address))
        .toList();
    final selected = preferred.isNotEmpty ? preferred.first : addresses.first;
    _ipCache[host] = selected.address;
    return selected.address;
  }

  Future<_MmdbCountryReader?> _loadReader() {
    return _readerFuture ??= _loadReaderFromAsset();
  }

  Future<_MmdbCountryReader?> _loadReaderFromAsset() async {
    try {
      final compressed = await rootBundle.load('assets/geoip.metadb.gz');
      final bytes = gzip.decode(compressed.buffer.asUint8List());
      return _MmdbCountryReader(Uint8List.fromList(bytes));
    } catch (_) {
      return null;
    }
  }

  String _hostKey(String value) {
    var host = value.trim();
    if (host.isEmpty) return '';

    final parsedUri = Uri.tryParse(host);
    if (parsedUri != null && parsedUri.hasScheme && parsedUri.host.isNotEmpty) {
      host = parsedUri.host;
    }

    if (host.startsWith('[')) {
      final end = host.indexOf(']');
      if (end > 0) host = host.substring(1, end);
    }

    final slash = host.indexOf('/');
    if (slash >= 0) host = host.substring(0, slash);

    final ipv4Port =
        RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3}):\d+$').firstMatch(host);
    if (ipv4Port != null) host = ipv4Port.group(1)!;

    return host.trim().toLowerCase();
  }

  String _normalizeCountry(String? country) {
    final value = country?.trim().toUpperCase() ?? '';
    if (value.length != 2) return 'UN';
    if (value == 'UK') return 'GB';
    if (value == 'EL') return 'GR';
    if (RegExp(r'^[A-Z]{2}$').hasMatch(value)) return value;
    return 'UN';
  }

  bool _isPrivateAddress(String ip) {
    final address = InternetAddress.tryParse(ip);
    if (address == null) return false;
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }

    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      final first = bytes[0];
      final second = bytes[1];
      return first == 0 ||
          first == 10 ||
          first == 127 ||
          (first == 100 && second >= 64 && second <= 127) ||
          (first == 169 && second == 254) ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168);
    }

    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      return (bytes[0] & 0xfe) == 0xfc || bytes[0] == 0;
    }

    return false;
  }
}

class _MmdbCountryReader {
  _MmdbCountryReader(this._bytes) {
    final metadataStart = _metadataStart();
    if (metadataStart < 0) {
      throw const FormatException('Missing MaxMind metadata.');
    }

    final decoder = _MmdbDecoder(_bytes, baseOffset: 0);
    final result = decoder.decode(metadataStart);
    final metadata = result.value;
    if (metadata is! Map) {
      throw const FormatException('Invalid MaxMind metadata.');
    }

    _nodeCount = _readInt(metadata['node_count']);
    _recordSize = _readInt(metadata['record_size']);
    _ipVersion = _readInt(metadata['ip_version']);
    _nodeByteSize = _recordSize ~/ 4;
    _searchTreeSize = _nodeCount * _nodeByteSize;
    _dataDecoder = _MmdbDecoder(_bytes, baseOffset: _searchTreeSize);
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

    var node = address.type == InternetAddressType.IPv4 && _ipVersion == 6
        ? _ipv4StartNode
        : 0;
    final bitCount = address.type == InternetAddressType.IPv4 ? 32 : 128;
    final raw = address.rawAddress;

    for (var i = 0; i < bitCount; i++) {
      final bit = (raw[i >> 3] >> (7 - (i & 7))) & 1;
      node = _readNode(node, bit);
      if (node == _nodeCount) return null;
      if (node > _nodeCount) {
        final offset = node - _nodeCount;
        final decoded = _dataDecoder.decode(_searchTreeSize + offset).value;
        return _extractCountryCode(decoded);
      }
    }

    return null;
  }

  int _metadataStart() {
    for (var i = _bytes.length - _metadataMarker.length; i >= 0; i--) {
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
    if (offset < 0 || offset + _nodeByteSize > _bytes.length) return _nodeCount;

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

    if (value is List<int>) return _extractCountryCodeFromBytes(value);

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

      for (final nested in value.values) {
        final result = _extractCountryCode(nested);
        if (result != null) return result;
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

  String? _extractCountryCodeFromBytes(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final text = latin1.decode(bytes, allowInvalid: true).toUpperCase();
    final matches = RegExp(r'[A-Z]{2}').allMatches(text);
    const ignored = {'BB', 'BI'};
    for (final match in matches) {
      final code = match.group(0);
      if (code != null && !ignored.contains(code)) {
        return _validCountryCode(code);
      }
    }
    return null;
  }

  String? _validCountryCode(String? value) {
    final code = value?.trim().toUpperCase() ?? '';
    if (code.length != 2) return null;
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(code)) return null;
    if (code == 'UK') return 'GB';
    if (code == 'EL') return 'GR';
    return code;
  }
}

class _MmdbDecoder {
  const _MmdbDecoder(this._bytes, {required this.baseOffset});

  final Uint8List _bytes;
  final int baseOffset;

  _MmdbValue decode(int offset) {
    final header = _readHeader(offset);
    var cursor = header.offset;

    switch (header.type) {
      case 1:
        final pointerOffset = baseOffset + header.pointer;
        final pointed = decode(pointerOffset);
        return _MmdbValue(pointed.value, cursor);
      case 2:
        final end = cursor + header.size;
        return _MmdbValue(utf8.decode(_bytes.sublist(cursor, end)), end);
      case 3:
        final end = cursor + header.size;
        return _MmdbValue(null, end);
      case 4:
        final end = cursor + header.size;
        return _MmdbValue(_bytes.sublist(cursor, end), end);
      case 5:
      case 6:
      case 8:
      case 9:
      case 10:
        var value = 0;
        final end = cursor + header.size;
        while (cursor < end) {
          value = (value << 8) | _bytes[cursor];
          cursor++;
        }
        return _MmdbValue(value, cursor);
      case 7:
        final map = <String, Object?>{};
        for (var i = 0; i < header.size; i++) {
          final key = decode(cursor);
          cursor = key.offset;
          final value = decode(cursor);
          cursor = value.offset;
          map[key.value.toString()] = value.value;
        }
        return _MmdbValue(map, cursor);
      case 11:
        final list = <Object?>[];
        for (var i = 0; i < header.size; i++) {
          final item = decode(cursor);
          cursor = item.offset;
          list.add(item.value);
        }
        return _MmdbValue(list, cursor);
      case 14:
        return _MmdbValue(header.size != 0, cursor);
      case 15:
        final end = cursor + header.size;
        return _MmdbValue(null, end);
      default:
        return _MmdbValue(null, cursor + header.size);
    }
  }

  _MmdbHeader _readHeader(int offset) {
    final control = _bytes[offset];
    var cursor = offset + 1;
    var type = control >> 5;
    var size = control & 0x1f;
    var pointer = 0;

    if (type == 0) {
      type = _bytes[cursor] + 7;
      cursor++;
    }

    if (type == 1) {
      final pointerSize = ((control >> 3) & 0x03) + 1;
      pointer = control & (0xff >> (pointerSize + 3));
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
      size = 29 + _bytes[cursor];
      cursor++;
    } else if (size == 30) {
      size = 285 + ((_bytes[cursor] << 8) | _bytes[cursor + 1]);
      cursor += 2;
    } else if (size == 31) {
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
