import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../constants/app_constants.dart';

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
  }) async {
    return (await fetchResponse(
      url,
      headers: headers,
      maxRedirects: maxRedirects,
      maxBodyBytes: maxBodyBytes,
    ))
        .body;
  }

  /// 直连下载订阅并保留响应头(带重定向跟随)
  static Future<DirectFetchResponse> fetchResponse(
    String url, {
    Map<String, String> headers = const {},
    int maxRedirects = 4,
    int maxBodyBytes = AppConstants.maxSubscriptionBytes,
  }) async {
    final bindAddr = await _physicalInterfaceAddress();
    var current = Uri.parse(url);

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final host = current.host;
      final isHttps = current.scheme == 'https';
      final port = current.hasPort ? current.port : (isHttps ? 443 : 80);

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
          host: host,
          path: pathAndQuery,
          accept: headers['Accept'] ?? '*/*',
          userAgent: headers['User-Agent'],
          maxBodyBytes: maxBodyBytes,
        );
      } finally {
        stream.destroy();
      }

      if (resp.statusCode >= 300 &&
          resp.statusCode < 400 &&
          resp.headers['location'] != null) {
        current = current.resolve(resp.headers['location']!);
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

    final raw = <int>[];
    var headerEnd = -1;
    Map<String, String>? headers;
    var isChunked = false;
    await for (final chunk
        in socket.timeout(_readTimeout, onTimeout: (sink) => sink.close())) {
      raw.addAll(chunk);
      if (headerEnd < 0) {
        headerEnd = _findHeaderEnd(raw);
        if (headerEnd < 0 && raw.length > _maxHeaderBytes) {
          throw Exception('HTTP 响应头过大');
        }
      }
      if (headerEnd >= 0 && headers == null) {
        final headerText =
            utf8.decode(raw.sublist(0, headerEnd), allowMalformed: true);
        headers = _parseHeaders(headerText.split('\r\n').skip(1));
        final contentLength = headers['content-length'];
        if (contentLength != null) {
          final size = int.tryParse(contentLength);
          if (size != null && size > maxBodyBytes) {
            throw Exception('订阅内容超过 20 MB 限制');
          }
        }
        isChunked = headers['transfer-encoding']?.toLowerCase() == 'chunked';
      }
      if (headerEnd >= 0 &&
          !isChunked &&
          raw.length - headerEnd - 4 > maxBodyBytes) {
        throw Exception('订阅内容超过 20 MB 限制');
      }
    }
    if (raw.isEmpty) throw Exception('服务器无响应(直连通道)');

    // 切分头与体
    headerEnd = headerEnd < 0 ? _findHeaderEnd(raw) : headerEnd;
    if (headerEnd < 0) throw Exception('HTTP 响应格式错误');

    final headerText =
        utf8.decode(raw.sublist(0, headerEnd), allowMalformed: true);
    final lines = headerText.split('\r\n');
    final statusMatch =
        RegExp(r'^HTTP/\d\.\d\s+(\d{3})').firstMatch(lines.first);
    if (statusMatch == null) throw Exception('HTTP 状态行解析失败');
    final statusCode = int.parse(statusMatch.group(1)!);

    headers ??= _parseHeaders(lines.skip(1));

    var bodyBytes = raw.sublist(headerEnd + 4);
    // 提前检查 Content-Length，避免超大响应消耗流量
    final contentLength = headers['content-length'];
    if (contentLength != null) {
      final size = int.tryParse(contentLength);
      if (size != null && size > maxBodyBytes) {
        throw Exception('订阅内容超过 20 MB 限制');
      }
    }
    if (headers['transfer-encoding']?.toLowerCase() == 'chunked') {
      bodyBytes = _decodeChunked(bodyBytes);
      if (bodyBytes.length > maxBodyBytes) {
        throw Exception('订阅内容超过 20 MB 限制');
      }
    }
    return _HttpResponse(
      statusCode: statusCode,
      headers: headers,
      body: utf8.decode(bodyBytes, allowMalformed: true),
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

  static int _findHeaderEnd(List<int> raw) {
    for (var i = 0; i + 3 < raw.length; i++) {
      if (raw[i] == 13 &&
          raw[i + 1] == 10 &&
          raw[i + 2] == 13 &&
          raw[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// 解析 chunked 传输编码
  static List<int> _decodeChunked(List<int> data) {
    final out = <int>[];
    var pos = 0;
    while (pos < data.length) {
      var lineEnd = pos;
      while (lineEnd + 1 < data.length &&
          !(data[lineEnd] == 13 && data[lineEnd + 1] == 10)) {
        lineEnd++;
      }
      if (lineEnd + 1 >= data.length) break;
      final sizeLine = String.fromCharCodes(data.sublist(pos, lineEnd));
      final size = int.tryParse(sizeLine.split(';').first.trim(), radix: 16);
      if (size == null || size == 0) break;
      final chunkStart = lineEnd + 2;
      final chunkEnd = chunkStart + size;
      if (chunkEnd > data.length) {
        out.addAll(data.sublist(chunkStart));
        break;
      }
      out.addAll(data.sublist(chunkStart, chunkEnd));
      pos = chunkEnd + 2; // 跳过块末尾的 \r\n
    }
    return out;
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
