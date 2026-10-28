import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An explicit, bounded query to the active core resolver. This does not prove
/// which answers a website request used, nor reveal upstream/cache identity.
class CoreDnsDiagnostic {
  CoreDnsDiagnostic({this.timeout = const Duration(seconds: 4)});
  final Duration timeout;
  final _clients = <HttpClient>{};
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    for (final client in _clients) {
      client.close(force: true);
    }
  }

  Future<String> inspect(String host,
      {required int apiPort, required Map<String, String> headers}) async {
    // The caller validates the public website target; enforce a bounded DNS
    // name here as well, so this API cannot become a general controller client.
    if (host.length > 253 || !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(host)) {
      return 'DNS：域名无效';
    }
    final results = await Future.wait([
      for (final type in ['A', 'AAAA']) _query(host, type, apiPort, headers),
    ]);
    if (_cancelled) return 'DNS：诊断已取消';
    return '$host\n${results.join('\n')}\n'
        '这是访问后向当前核心发起的独立查询，不代表本次网站请求采用的地址。'
        '耗时包含控制接口往返；上游服务器和缓存命中情况未知。';
  }

  Future<String> _query(
      String host, String type, int port, Map<String, String> headers) async {
    if (_cancelled) return '$type：诊断已取消';
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    _clients.add(client);
    final watch = Stopwatch()..start();
    try {
      final result = await (() async {
        final request = await client.getUrl(Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: port,
            path: '/dns/query',
            queryParameters: {'name': host, 'type': type}));
        if (_cancelled) return '诊断已取消';
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        final response = await request.close();
        if (response.statusCode != 200) {
          return switch (response.statusCode) {
            401 || 403 => '控制接口未授权',
            404 || 405 => '当前核心不支持 DNS 查询',
            _ => 'DNS 接口不可用（HTTP ${response.statusCode}）',
          };
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 32768) {
            return '响应过大，未解析';
          }
          bytes.addAll(chunk);
        }
        return _parse(jsonDecode(utf8.decode(bytes)), type);
      })()
          .timeout(timeout);
      return '$type：${_cancelled ? '诊断已取消' : result} · ${watch.elapsedMilliseconds} ms';
    } on TimeoutException {
      return '$type：查询超时';
    } on FormatException {
      return '$type：响应格式无效';
    } catch (_) {
      return '$type：${_cancelled ? '诊断已取消' : 'DNS 接口不可用'}';
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }

  String _parse(dynamic data, String type) {
    if (data is! Map || data['Status'] is! int) {
      throw const FormatException();
    }
    final code = data['Status'] as int;
    if (code < 0 || code > 15) throw const FormatException();
    if (data['TC'] == true) return '响应被截断，结果不完整';
    if (code == 3) return '域名不存在（NXDOMAIN）';
    if (code != 0) return '解析失败（DNS 状态 $code）';
    final answers = data['Answer'];
    if (answers == null) return '未返回此类型地址（NODATA）';
    if (answers is! List || answers.length > 128) {
      throw const FormatException();
    }
    final values = <String>{};
    for (final answer in answers) {
      if (answer is! Map) throw const FormatException();
      if (answer['type'] != (type == 'A' ? 1 : 28)) continue;
      final raw = answer['data'];
      final ip = raw is String ? InternetAddress.tryParse(raw) : null;
      if (ip == null ||
          ip.type !=
              (type == 'A'
                  ? InternetAddressType.IPv4
                  : InternetAddressType.IPv6)) {
        throw const FormatException();
      }
      values.add(ip.address);
    }
    if (values.isEmpty) return '未返回此类型地址（NODATA）';
    return '${values.take(16).join('、')}${values.length > 16 ? '（仅显示前 16 项）' : ''}';
  }
}
