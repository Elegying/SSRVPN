import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../constants/app_constants.dart';
import '../utils/subscription_url_policy.dart';

/// 订阅“真·直连”下载器（桌面优先）
///
/// 解决两类环境问题：
/// 1. 系统 DNS 被代理软件的 fake-ip 劫持（解析结果落在 198.18.0.0/15），
///    导致按域名连接时打到假 IP 上；
/// 2. 其他 VPN 的 TUN 虚拟网卡接管了默认路由，而订阅服务器只允许
///    大陆直连访问、屏蔽代理出口 IP。
///
/// 做法：通过 DoH（阿里 DNS，按 IP 直连无需解析）拿到真实 IP，
/// 然后把 socket 绑定到物理网卡（en0 等）的地址上建立连接，
/// 让流量从真实网卡直接出去，绕开假 DNS 与 TUN 路由。
///
/// 注意：macOS 会优先绑定 en0/en1 等物理网卡；Windows/Android 没有同名
/// 网卡时会自动退化为不绑定源地址的 DoH + IP 直连路径。
class DirectFetcher {
  static const _dohIp = '223.5.5.5';
  static const _dohHost = 'dns.alidns.com';
  static const _connectTimeout = Duration(seconds: 8);
  static const _readTimeout = Duration(seconds: 30);
  static const _requestTimeout = Duration(seconds: 60);
  static const _maxHeaderBytes = 64 * 1024;

  /// 判断 IP 是否落在 Clash fake-ip 常用网段 198.18.0.0/15
  static bool isFakeIp(InternetAddress addr) {
    if (addr.type != InternetAddressType.IPv4) return false;
    final b = addr.rawAddress;
    return b[0] == 198 && (b[1] == 18 || b[1] == 19);
  }

  /// 系统 DNS 是否已被 fake-ip 污染(用于决定是否提前走直连通道)
  static Future<bool> systemDnsPoisoned(String host) async {
    try {
      final addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 4));
      if (addrs.isEmpty) return false;
      return addrs.every(isFakeIp);
    } catch (_) {
      return false;
    }
  }

  /// 找到物理网卡的 IPv4 地址(跳过回环 / utun / fake-ip / 链路本地)
  static Future<InternetAddress?> _physicalInterfaceAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      // 优先 en0/en1(macOS 的 Wi-Fi / 以太网)
      interfaces.sort((a, b) {
        int rank(NetworkInterface i) => i.name.startsWith('en') ? 0 : 1;
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.name.compareTo(b.name);
      });
      for (final iface in interfaces) {
        if (iface.name.startsWith('utun') ||
            iface.name.startsWith('tun') ||
            iface.name.startsWith('tap') ||
            iface.name.startsWith('bridge') ||
            iface.name.startsWith('awdl') ||
            iface.name.startsWith('llw')) {
          continue;
        }
        for (final addr in iface.addresses) {
          if (isFakeIp(addr)) continue;
          final b = addr.rawAddress;
          if (b[0] == 169 && b[1] == 254) continue; // 链路本地
          return addr;
        }
      }
    } catch (_) {}
    return null;
  }

  /// 通过 DoH 解析域名的真实 A 记录(连接按 IP 直达,不依赖系统 DNS)
  static Future<List<String>> _resolveViaDoH(
      String host, InternetAddress? bindAddr) async {
    final socket = await Socket.connect(_dohIp, 443,
        sourceAddress: bindAddr, timeout: _connectTimeout);
    SecureSocket tls;
    try {
      tls = await SecureSocket.secure(socket, host: _dohHost)
          .timeout(_connectTimeout);
    } catch (e) {
      socket.destroy();
      rethrow;
    }
    try {
      final body = await _httpGetOverSocket(
        tls,
        host: _dohHost,
        path: '/resolve?name=${Uri.encodeComponent(host)}&type=A',
        accept: 'application/dns-json',
      );
      final json = jsonDecode(body.body) as Map<String, dynamic>;
      final answers = json['Answer'] as List? ?? [];
      return answers
          .where((a) => a is Map && a['type'] == 1)
          .map((a) => (a as Map)['data'].toString())
          .toList();
    } finally {
      tls.destroy();
    }
  }

  /// 直连下载订阅(带重定向跟随)
  static Future<String> fetch(
    String url, {
    Map<String, String> headers = const {},
    int maxRedirects = 4,
    int maxBodyBytes = AppConstants.maxSubscriptionBytes,
    Duration requestTimeout = _requestTimeout,
  }) async {
    return (await fetchResponse(
      url,
      headers: headers,
      maxRedirects: maxRedirects,
      maxBodyBytes: maxBodyBytes,
      requestTimeout: requestTimeout,
    ))
        .body;
  }

  /// 直连下载订阅并保留响应头(带重定向跟随)
  static Future<DirectFetchResponse> fetchResponse(
    String url, {
    Map<String, String> headers = const {},
    int maxRedirects = 4,
    int maxBodyBytes = AppConstants.maxSubscriptionBytes,
    Duration requestTimeout = _requestTimeout,
  }) async {
    final bindAddr = await _physicalInterfaceAddress();
    var current = SubscriptionUrlPolicy.parse(url);

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final host = current.host;
      final isHttps = current.scheme == 'https';
      final port = current.hasPort ? current.port : (isHttps ? 443 : 80);
      final hostHeader = current.hasPort ? '$host:$port' : host;

      // 解析真实 IP:IP 直填则跳过;否则优先 DoH,失败回退系统 DNS(过滤 fake-ip)
      String connectIp;
      final hostAddress = InternetAddress.tryParse(host);
      if (hostAddress != null) {
        connectIp = host;
      } else {
        List<String> ips = [];
        try {
          ips = await _resolveViaDoH(host, bindAddr);
        } catch (_) {}
        if (ips.isEmpty) {
          final sys = await InternetAddress.lookup(host)
              .timeout(const Duration(seconds: 5));
          ips = sys
              .where((a) => a.type == InternetAddressType.IPv4 && !isFakeIp(a))
              .map((a) => a.address)
              .toList();
        }
        if (ips.isEmpty) {
          throw Exception('无法解析订阅服务器地址: $host');
        }
        connectIp = ips.first;
      }

      final sourceAddress =
          _canBindSourceAddress(hostAddress) ? bindAddr : null;
      final socket = await Socket.connect(connectIp, port,
          sourceAddress: sourceAddress, timeout: _connectTimeout);
      Socket stream = socket;
      if (isHttps) {
        try {
          stream = await SecureSocket.secure(socket, host: host)
              .timeout(_connectTimeout);
        } catch (e) {
          socket.destroy();
          rethrow;
        }
      }

      _HttpResponse resp;
      try {
        final basePath = current.path.isEmpty ? '/' : current.path;
        final pathAndQuery =
            basePath + (current.hasQuery ? '?${current.query}' : '');
        resp = await _httpGetOverSocket(
          stream,
          host: hostHeader,
          path: pathAndQuery,
          accept: headers['Accept'] ?? '*/*',
          userAgent: headers['User-Agent'],
          maxBodyBytes: maxBodyBytes,
          requestTimeout: requestTimeout,
        );
      } finally {
        stream.destroy();
      }

      if (SubscriptionUrlPolicy.isRedirectStatus(resp.statusCode)) {
        current = SubscriptionUrlPolicy.resolveRedirect(
          current,
          resp.headers['location'] ?? '',
        );
        continue;
      }
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}: 订阅获取失败(直连通道)');
      }
      return DirectFetchResponse(headers: resp.headers, body: resp.body);
    }
    throw Exception('重定向次数过多');
  }

  static bool _canBindSourceAddress(InternetAddress? address) {
    if (address == null) return true;
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      final first = bytes[0];
      final second = bytes[1];
      return !(first == 10 ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168));
    }
    return false;
  }

  /// 在已建立的 socket 上执行一次 HTTP/1.1 GET(identity 编码 + chunked 解析)
  static Future<_HttpResponse> _httpGetOverSocket(
    Socket socket, {
    required String host,
    required String path,
    String accept = '*/*',
    String? userAgent,
    int maxBodyBytes = AppConstants.maxSubscriptionBytes,
    Duration requestTimeout = _requestTimeout,
  }) async {
    final request = StringBuffer()
      ..write('GET $path HTTP/1.1\r\n')
      ..write('Host: $host\r\n')
      ..write('User-Agent: ${userAgent ?? AppConstants.appUserAgent}\r\n')
      ..write('Accept: $accept\r\n')
      ..write('Accept-Encoding: identity\r\n')
      ..write('Connection: close\r\n')
      ..write('\r\n');
    socket.add(utf8.encode(request.toString()));
    await socket.flush();

    final headerBytes = <int>[];
    final bodyBytes = BytesBuilder(copy: false);
    var bodyLength = 0;
    Map<String, String>? headers;
    int? statusCode;
    int? expectedBodyBytes;
    _ChunkedBodyDecoder? chunkedDecoder;
    var absoluteTimeoutExpired = false;
    final absoluteTimer = Timer(requestTimeout, () {
      absoluteTimeoutExpired = true;
      socket.destroy();
    });
    responseLoop:
    try {
      await for (final chunk in socket.timeout(_readTimeout)) {
        var offset = 0;
        while (headers == null && offset < chunk.length) {
          headerBytes.add(chunk[offset++]);
          if (headerBytes.length > _maxHeaderBytes) {
            throw Exception('HTTP 响应头过大');
          }

          final length = headerBytes.length;
          if (length < 4 ||
              headerBytes[length - 4] != 13 ||
              headerBytes[length - 3] != 10 ||
              headerBytes[length - 2] != 13 ||
              headerBytes[length - 1] != 10) {
            continue;
          }

          final headerText = utf8.decode(
            headerBytes.sublist(0, length - 4),
            allowMalformed: true,
          );
          final lines = headerText.split('\r\n');
          final statusMatch =
              RegExp(r'^HTTP/\d\.\d\s+(\d{3})').firstMatch(lines.first);
          if (statusMatch == null) throw Exception('HTTP 状态行解析失败');
          statusCode = int.parse(statusMatch.group(1)!);
          headers = _parseHeaders(lines.skip(1));

          final contentLength = headers['content-length']?.trim();
          if (contentLength != null) {
            final size = int.tryParse(contentLength);
            if (!RegExp(r'^\d+$').hasMatch(contentLength) || size == null) {
              throw Exception('HTTP Content-Length 格式错误');
            }
            if (size > maxBodyBytes) {
              throw Exception('订阅内容超过 20 MB 限制');
            }
            expectedBodyBytes = size;
          }

          final transferEncodings = (headers['transfer-encoding'] ?? '')
              .toLowerCase()
              .split(',')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList(growable: false);
          if (transferEncodings.isNotEmpty) {
            if (transferEncodings.length != 1 ||
                transferEncodings.single != 'chunked') {
              throw Exception('HTTP Transfer-Encoding 不受支持');
            }
            if (expectedBodyBytes != null) {
              throw Exception('HTTP 响应长度声明冲突');
            }
            chunkedDecoder = _ChunkedBodyDecoder(maxBodyBytes);
          } else if (expectedBodyBytes == 0) {
            break responseLoop;
          }
        }

        if (headers == null || offset == chunk.length) continue;
        if (chunkedDecoder != null) {
          chunkedDecoder.add(chunk, offset);
          if (chunkedDecoder.isComplete) break responseLoop;
        } else {
          final incoming = chunk.length - offset;
          final nextLength = bodyLength + incoming;
          if (nextLength > maxBodyBytes) {
            throw Exception('订阅内容超过 20 MB 限制');
          }
          if (expectedBodyBytes != null && nextLength > expectedBodyBytes) {
            throw Exception('HTTP 正文超过 Content-Length');
          }
          bodyBytes.add(chunk.sublist(offset));
          bodyLength = nextLength;
          if (expectedBodyBytes != null && bodyLength == expectedBodyBytes) {
            break responseLoop;
          }
        }
      }
    } finally {
      absoluteTimer.cancel();
    }
    if (absoluteTimeoutExpired) {
      throw TimeoutException('HTTP 响应超过绝对时限', requestTimeout);
    }
    if (headerBytes.isEmpty) throw Exception('服务器无响应(直连通道)');
    if (headers == null || statusCode == null) {
      throw Exception('HTTP 响应格式错误');
    }

    if (expectedBodyBytes != null && bodyLength != expectedBodyBytes) {
      throw Exception('HTTP 正文短于 Content-Length');
    }
    final decodedBody = chunkedDecoder?.finish() ?? bodyBytes.takeBytes();
    return _HttpResponse(
      statusCode: statusCode,
      headers: headers,
      body: utf8.decode(decodedBody, allowMalformed: true),
    );
  }

  static Map<String, String> _parseHeaders(Iterable<String> lines) {
    final headers = <String, String>{};
    for (final line in lines) {
      final idx = line.indexOf(':');
      if (idx > 0) {
        headers[line.substring(0, idx).trim().toLowerCase()] =
            line.substring(idx + 1).trim();
      }
    }
    return headers;
  }
}

class _ChunkedBodyDecoder {
  static const _maxMetadataBytes = 64 * 1024;

  final int maxBodyBytes;
  final BytesBuilder _body = BytesBuilder(copy: false);
  final List<int> _line = <int>[];
  int _bodyLength = 0;
  int? _chunkBytesRemaining;
  int _chunkTerminatorOffset = 0;
  int _trailerBytes = 0;
  bool _readingTrailers = false;
  bool _complete = false;

  _ChunkedBodyDecoder(this.maxBodyBytes);

  bool get isComplete => _complete;

  void add(List<int> data, [int offset = 0]) {
    while (offset < data.length && !_complete) {
      if (_readingTrailers) {
        _trailerBytes++;
        if (_trailerBytes > _maxMetadataBytes) {
          throw Exception('HTTP chunked 尾部过大');
        }
        _line.add(data[offset++]);
        if (_lineEndsWithCrlf()) {
          if (_line.length == 2) _complete = true;
          _line.clear();
        }
        continue;
      }

      if (_chunkBytesRemaining == null) {
        _line.add(data[offset++]);
        if (_line.length > _maxMetadataBytes) {
          throw Exception('HTTP chunk 大小行过大');
        }
        if (!_lineEndsWithCrlf()) continue;

        final sizeLine = String.fromCharCodes(_line.take(_line.length - 2));
        _line.clear();
        final size = int.tryParse(sizeLine.split(';').first.trim(), radix: 16);
        if (size == null || size < 0) {
          throw Exception('HTTP chunk 大小格式错误');
        }
        if (size == 0) {
          _readingTrailers = true;
          continue;
        }
        if (size > maxBodyBytes - _bodyLength) {
          throw Exception('订阅内容超过 20 MB 限制');
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
        throw Exception('HTTP chunk 结束符格式错误');
      }
      _chunkTerminatorOffset++;
      if (_chunkTerminatorOffset == 2) {
        _chunkTerminatorOffset = 0;
        _chunkBytesRemaining = null;
      }
    }
  }

  List<int> finish() {
    if (!_complete) throw Exception('HTTP chunked 响应不完整');
    return _body.takeBytes();
  }

  bool _lineEndsWithCrlf() {
    final length = _line.length;
    return length >= 2 && _line[length - 2] == 13 && _line[length - 1] == 10;
  }
}

class DirectFetchResponse {
  final Map<String, String> headers;
  final String body;
  DirectFetchResponse({required this.headers, required this.body});
}

class _HttpResponse {
  final int statusCode;
  final Map<String, String> headers;
  final String body;
  _HttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });
}
