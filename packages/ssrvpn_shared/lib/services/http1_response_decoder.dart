import 'dart:typed_data';

import 'subscription_text_decoder.dart';

final RegExp _httpTokenPattern = RegExp(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+");

bool _isHttpToken(String value) {
  final match = _httpTokenPattern.matchAsPrefix(value);
  return value.isNotEmpty && match?.end == value.length;
}

bool _isHttpFieldValue(String value) => value.codeUnits.every(
      (codeUnit) =>
          codeUnit == 9 ||
          (codeUnit >= 32 && codeUnit <= 126) ||
          codeUnit >= 128,
    );

String _bodyLimitMessage(int maxBodyBytes) {
  const bytesPerMegabyte = 1024 * 1024;
  final limit =
      maxBodyBytes >= bytesPerMegabyte && maxBodyBytes % bytesPerMegabyte == 0
          ? '${maxBodyBytes ~/ bytesPerMegabyte} MB'
          : '$maxBodyBytes bytes';
  return 'HTTP 正文超过 $limit 限制';
}

int? _parseUnsignedWithinLimit(
  String digits, {
  required int radix,
  required int limit,
}) {
  final maxBeforeMultiply = limit ~/ radix;
  final maxLastDigit = limit % radix;
  var value = 0;
  for (var offset = 0; offset < digits.length; offset++) {
    final codeUnit = digits.codeUnitAt(offset);
    final digit = codeUnit <= 57 ? codeUnit - 48 : (codeUnit | 32) - 87;
    assert(digit >= 0 && digit < radix);
    if (value > maxBeforeMultiply ||
        (value == maxBeforeMultiply && digit > maxLastDigit)) {
      return null;
    }
    value = value * radix + digit;
  }
  return value;
}

/// Incrementally decodes one HTTP/1.x response without owning its socket.
///
/// Socket deadlines, cancellation, logging, content decoding and redirects
/// remain caller responsibilities. This class owns only response framing.
/// The total wire budget is [maxBodyBytes] + [maxHeaderBytes], so the latter
/// also reserves bounded space for chunk metadata and other framing overhead.
class Http1ResponseDecoder {
  Http1ResponseDecoder({
    required this.maxBodyBytes,
    this.maxHeaderBytes = 64 * 1024,
  }) {
    if (maxBodyBytes < 0) {
      throw ArgumentError('maxBodyBytes must be non-negative');
    }
    if (maxHeaderBytes <= 0) {
      throw ArgumentError('maxHeaderBytes must be positive');
    }
  }

  final int maxBodyBytes;
  final int maxHeaderBytes;

  final List<int> _headerBytes = <int>[];
  final BytesBuilder _bodyBytes = BytesBuilder(copy: false);
  int _bodyLength = 0;
  int _wireBytes = 0;
  Map<String, String>? _headers;
  int? _statusCode;
  int? _expectedBodyBytes;
  _ChunkedBodyDecoder? _chunkedDecoder;
  bool _complete = false;
  Http1DecodedResponse? _finished;

  bool get isComplete => _complete;
  int get wireBytes => _wireBytes;

  void add(List<int> data) {
    if (data.isEmpty) return;
    if (_finished != null) {
      throw const FormatException('HTTP 响应已结束');
    }

    _wireBytes += data.length;
    if (_wireBytes > maxBodyBytes + maxHeaderBytes) {
      throw Exception(
        'HTTP 响应超过 ${maxBodyBytes + maxHeaderBytes} bytes wire 限制',
      );
    }

    var offset = 0;
    while (_headers == null && offset < data.length) {
      _headerBytes.add(data[offset++]);
      if (_headerBytes.length > maxHeaderBytes) {
        throw Exception('HTTP 响应头超过 $maxHeaderBytes bytes 限制');
      }
      if (!_endsWithHeaderDelimiter(_headerBytes)) continue;
      _parseHeaders();
    }

    if (_headers == null || offset == data.length) return;
    if (_complete) {
      throw const FormatException('HTTP 响应后存在多余字节');
    }

    final chunkedDecoder = _chunkedDecoder;
    if (chunkedDecoder != null) {
      chunkedDecoder.add(data, offset);
      if (chunkedDecoder.isComplete) _complete = true;
      return;
    }

    final incoming = data.length - offset;
    final nextLength = _bodyLength + incoming;
    if (nextLength > maxBodyBytes) {
      throw Exception(_bodyLimitMessage(maxBodyBytes));
    }
    final expectedBodyBytes = _expectedBodyBytes;
    if (expectedBodyBytes != null && nextLength > expectedBodyBytes) {
      throw const FormatException('HTTP 正文超过 Content-Length');
    }
    _bodyBytes.add(data.sublist(offset));
    _bodyLength = nextLength;
    if (expectedBodyBytes != null && _bodyLength == expectedBodyBytes) {
      _complete = true;
    }
  }

  Http1DecodedResponse finish() {
    final finished = _finished;
    if (finished != null) return finished;

    final headers = _headers;
    final statusCode = _statusCode;
    if (headers == null || statusCode == null) {
      throw const FormatException('HTTP 响应格式错误');
    }
    final expectedBodyBytes = _expectedBodyBytes;
    if (expectedBodyBytes != null && _bodyLength != expectedBodyBytes) {
      throw const FormatException('HTTP 正文短于 Content-Length');
    }
    final body = _chunkedDecoder?.finish() ?? _bodyBytes.takeBytes();
    if (body.length > maxBodyBytes) {
      throw Exception(_bodyLimitMessage(maxBodyBytes));
    }
    _complete = true;
    return _finished = Http1DecodedResponse(
      statusCode: statusCode,
      headers: Map.unmodifiable(headers),
      bodyBytes: body,
    );
  }

  void _parseHeaders() {
    final headerText = decodeHttp1HeaderBytes(
      _headerBytes.sublist(0, _headerBytes.length - 4),
    );
    final lines = headerText.split('\r\n');
    final statusMatch = RegExp(
      r'^HTTP/\d\.\d ([0-9]{3})(?: .*)?$',
    ).firstMatch(lines.first);
    if (statusMatch == null) {
      throw const FormatException('HTTP 状态行解析失败');
    }
    final statusCode = int.parse(statusMatch.group(1)!);

    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final separator = line.indexOf(':');
      if (separator <= 0) {
        throw const FormatException('HTTP 响应头格式错误');
      }
      final rawName = line.substring(0, separator);
      if (!_isHttpToken(rawName)) {
        throw const FormatException('HTTP 响应头名称格式错误');
      }
      final name = rawName.toLowerCase();
      final rawValue = line.substring(separator + 1);
      if (!_isHttpFieldValue(rawValue)) {
        throw const FormatException('HTTP 响应头字段值格式错误');
      }
      final value = rawValue.trim();
      if ((name == 'content-length' || name == 'transfer-encoding') &&
          headers.containsKey(name)) {
        throw FormatException('HTTP $name 重复');
      }
      headers[name] = value;
    }

    final contentLength = headers['content-length']?.trim();
    if (contentLength != null) {
      if (!RegExp(r'^\d+$').hasMatch(contentLength)) {
        throw const FormatException('HTTP Content-Length 格式错误');
      }
    }

    final transferEncoding = headers['transfer-encoding'];
    if (transferEncoding != null) {
      if (contentLength != null) {
        throw const FormatException('HTTP 响应长度声明冲突');
      }
      final transferEncodings = transferEncoding
          .toLowerCase()
          .split(',')
          .map((value) => value.trim())
          .toList(growable: false);
      if (transferEncodings.length != 1 ||
          transferEncodings.single != 'chunked') {
        throw const FormatException('HTTP Transfer-Encoding 不受支持');
      }
    }

    if (statusCode == 101) {
      throw const FormatException('HTTP 协议切换响应不受支持');
    }
    if (statusCode >= 100 && statusCode < 200) {
      _headerBytes.clear();
      return;
    }

    _statusCode = statusCode;
    _headers = headers;
    if (statusCode == 204 || statusCode == 304) {
      _complete = true;
      return;
    }

    final parsedContentLength = contentLength == null
        ? null
        : _parseUnsignedWithinLimit(
            contentLength,
            radix: 10,
            limit: maxBodyBytes,
          );
    if (contentLength != null && parsedContentLength == null) {
      throw Exception(_bodyLimitMessage(maxBodyBytes));
    }
    if (parsedContentLength != null) {
      _expectedBodyBytes = parsedContentLength;
    }

    if (transferEncoding != null) {
      _chunkedDecoder = _ChunkedBodyDecoder(
        maxBodyBytes: maxBodyBytes,
        maxMetadataBytes: maxHeaderBytes,
      );
    } else if (_expectedBodyBytes == 0) {
      _complete = true;
    }
  }

  static bool _endsWithHeaderDelimiter(List<int> bytes) {
    final length = bytes.length;
    return length >= 4 &&
        bytes[length - 4] == 13 &&
        bytes[length - 3] == 10 &&
        bytes[length - 2] == 13 &&
        bytes[length - 1] == 10;
  }
}

class Http1DecodedResponse {
  const Http1DecodedResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final List<int> bodyBytes;
}

class _ChunkedBodyDecoder {
  static final RegExp _chunkSizePattern = RegExp(r'[0-9A-Fa-f]+');

  _ChunkedBodyDecoder({
    required this.maxBodyBytes,
    required this.maxMetadataBytes,
  });

  final int maxBodyBytes;
  final int maxMetadataBytes;
  final BytesBuilder _body = BytesBuilder(copy: false);
  final List<int> _line = <int>[];
  int _bodyLength = 0;
  int? _chunkBytesRemaining;
  int _chunkTerminatorOffset = 0;
  int _trailerBytes = 0;
  bool _readingTrailers = false;
  bool _complete = false;

  bool get isComplete => _complete;

  void add(List<int> data, [int offset = 0]) {
    while (offset < data.length && !_complete) {
      if (_readingTrailers) {
        _trailerBytes++;
        if (_trailerBytes > maxMetadataBytes) {
          throw const FormatException('HTTP chunked 尾部过大');
        }
        _line.add(data[offset++]);
        if (_lineEndsWithCrlf()) {
          if (_line.length == 2) {
            _complete = true;
          } else {
            _validateTrailerLine();
          }
          _line.clear();
        }
        continue;
      }

      if (_chunkBytesRemaining == null) {
        _line.add(data[offset++]);
        if (_line.length > maxMetadataBytes) {
          throw const FormatException('HTTP chunk 大小行过大');
        }
        if (!_lineEndsWithCrlf()) continue;

        final sizeLine = String.fromCharCodes(_line.take(_line.length - 2));
        _line.clear();
        final sizeMatch = _chunkSizePattern.matchAsPrefix(sizeLine);
        final sizeToken = sizeMatch?.group(0);
        final extensions =
            sizeMatch == null ? '' : sizeLine.substring(sizeMatch.end);
        if (sizeToken == null || !_hasValidChunkExtensions(extensions)) {
          throw const FormatException('HTTP chunk 大小格式错误');
        }
        final size = _parseUnsignedWithinLimit(
          sizeToken,
          radix: 16,
          limit: maxBodyBytes - _bodyLength,
        );
        if (size == null) {
          throw Exception(_bodyLimitMessage(maxBodyBytes));
        }
        if (size == 0) {
          _readingTrailers = true;
          continue;
        }
        _chunkBytesRemaining = size;
        continue;
      }

      if (_chunkBytesRemaining! > 0) {
        final available = data.length - offset;
        final count = _chunkBytesRemaining! < available
            ? _chunkBytesRemaining!
            : available;
        _body.add(data.sublist(offset, offset + count));
        _bodyLength += count;
        offset += count;
        _chunkBytesRemaining = _chunkBytesRemaining! - count;
        continue;
      }

      final expected = _chunkTerminatorOffset == 0 ? 13 : 10;
      if (data[offset++] != expected) {
        throw const FormatException('HTTP chunk 结束符格式错误');
      }
      _chunkTerminatorOffset++;
      if (_chunkTerminatorOffset == 2) {
        _chunkTerminatorOffset = 0;
        _chunkBytesRemaining = null;
      }
    }
    if (_complete && offset < data.length) {
      throw const FormatException('HTTP 响应后存在多余字节');
    }
  }

  List<int> finish() {
    if (!_complete) throw const FormatException('HTTP chunked 响应不完整');
    return _body.takeBytes();
  }

  bool _lineEndsWithCrlf() {
    final length = _line.length;
    return length >= 2 && _line[length - 2] == 13 && _line[length - 1] == 10;
  }

  void _validateTrailerLine() {
    final line = String.fromCharCodes(_line.take(_line.length - 2));
    final separator = line.indexOf(':');
    if (separator <= 0 || !_isHttpToken(line.substring(0, separator))) {
      throw const FormatException('HTTP chunked 尾部字段格式错误');
    }
    if (!_isHttpFieldValue(line.substring(separator + 1))) {
      throw const FormatException('HTTP chunked 尾部字段值格式错误');
    }
    final name = line.substring(0, separator).toLowerCase();
    if (name == 'content-length' || name == 'transfer-encoding') {
      throw const FormatException('HTTP chunked 尾部包含禁止的 framing 字段');
    }
  }

  static bool _hasValidChunkExtensions(String value) {
    var offset = 0;
    while (offset < value.length) {
      while (
          offset < value.length && _isBadWhitespace(value.codeUnitAt(offset))) {
        offset++;
      }
      if (offset >= value.length || value.codeUnitAt(offset) != 59) {
        return false;
      }
      offset++;
      while (
          offset < value.length && _isBadWhitespace(value.codeUnitAt(offset))) {
        offset++;
      }
      final name = _httpTokenPattern.matchAsPrefix(value, offset);
      if (name == null) return false;
      offset = name.end;
      while (
          offset < value.length && _isBadWhitespace(value.codeUnitAt(offset))) {
        offset++;
      }
      if (offset >= value.length || value.codeUnitAt(offset) != 61) {
        continue;
      }
      offset++;
      while (
          offset < value.length && _isBadWhitespace(value.codeUnitAt(offset))) {
        offset++;
      }
      if (offset >= value.length) return false;

      if (value.codeUnitAt(offset) != 34) {
        final token = _httpTokenPattern.matchAsPrefix(value, offset);
        if (token == null) return false;
        offset = token.end;
        continue;
      }

      offset++;
      var closed = false;
      while (offset < value.length) {
        final codeUnit = value.codeUnitAt(offset++);
        if (codeUnit == 34) {
          closed = true;
          break;
        }
        if (codeUnit == 92) {
          if (offset >= value.length ||
              !_isQuotedPairCodeUnit(value.codeUnitAt(offset++))) {
            return false;
          }
        } else if (!_isQuotedTextCodeUnit(codeUnit)) {
          return false;
        }
      }
      if (!closed) return false;
    }
    return true;
  }

  static bool _isBadWhitespace(int codeUnit) => codeUnit == 9 || codeUnit == 32;

  static bool _isQuotedPairCodeUnit(int codeUnit) =>
      codeUnit == 9 ||
      codeUnit == 32 ||
      (codeUnit >= 33 && codeUnit <= 126) ||
      (codeUnit >= 128 && codeUnit <= 255);

  static bool _isQuotedTextCodeUnit(int codeUnit) =>
      codeUnit == 9 ||
      codeUnit == 32 ||
      codeUnit == 33 ||
      (codeUnit >= 35 && codeUnit <= 91) ||
      (codeUnit >= 93 && codeUnit <= 126) ||
      (codeUnit >= 128 && codeUnit <= 255);
}
