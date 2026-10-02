import 'dart:async';
import 'dart:io';
import '../models/site_diagnostic_report.dart';
import 'site_route_monitor.dart';

/// A user-triggered GET request through the local proxy and current routing rules.
/// Follows at most five public web redirects; never consumes bodies or changes connection state.
class SiteAccessDiagnostic {
  HttpClient? _client;
  SiteRouteMonitor? _monitor;
  bool _cancelled = false;
  static Uri parseTarget(String input) {
    if (input.length > 2048 || RegExp(r'[\x00-\x20\x7f]').hasMatch(input)) {
      throw const FormatException('请输入有效网站地址');
    }
    final value = input.contains('://') ? input : 'https://$input';
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.hasFragment ||
        uri.hasQuery ||
        uri.port != (uri.scheme == 'https' ? 443 : 80)) {
      throw const FormatException('请输入 HTTP/HTTPS 网站地址，不含账号、查询参数或自定义端口');
    }
    final host = uri.host.toLowerCase();
    // Domain targets only; the current proxy resolves DNS using the active rules.
    if (host.length > 253 ||
        !RegExp(r'^(?:[a-z]{2,63}|xn--[a-z0-9-]+)$')
            .hasMatch(host.split('.').last) ||
        InternetAddress.tryParse(host) != null ||
        !host.contains('.') ||
        host.endsWith('.') ||
        host.endsWith('.local') ||
        host.endsWith('.localhost') ||
        host.endsWith('.internal') ||
        !RegExp(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$').hasMatch(host) ||
        host.split('.').any(
              (label) =>
                  label.isEmpty ||
                  label.length > 63 ||
                  label.startsWith('-') ||
                  label.endsWith('-'),
            ) ||
        RegExp(r'^[0-9.]+$').hasMatch(host)) {
      throw const FormatException('请使用公开网站域名，不支持本机或 IP 地址');
    }
    return uri;
  }

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
    _monitor?.close();
  }

  Future<String> run(Uri target, {required int proxyPort}) async =>
      (await inspect(target, proxyPort: proxyPort)).summary;

  Future<SiteDiagnosticReport> inspect(Uri target,
      {required int proxyPort,
      int? apiPort,
      Map<String, String> apiHeaders = const {},
      void Function(String)? onStage}) async {
    parseTarget(target.toString());
    final history = <SiteDiagnosticReport>[];
    final visited = <String>{target.toString()};
    var current = target;
    while (true) {
      final result = await _inspectOnce(current,
          proxyPort: proxyPort,
          apiPort: apiPort,
          apiHeaders: apiHeaders,
          onStage: onStage);
      if (_cancelled ||
          ![301, 302, 303, 307, 308].contains(result.statusCode)) {
        return result.withRedirects(history);
      }
      if (result.redirectLocation == null) {
        return result.withRedirects(history, '网站要求跳转，但没有提供下一步地址。');
      }
      if (history.length >= 5) {
        return result.withRedirects(history, '网站连续跳转过多，尚未到达最终页面。');
      }
      Uri next;
      try {
        next = current.resolve(result.redirectLocation!).removeFragment();
        // Redirects commonly carry query parameters. Validate the destination
        // with the same domain/scheme/port policy without retaining credentials.
        if (next.userInfo.isNotEmpty || next.toString().length > 2048) {
          throw const FormatException();
        }
        parseTarget(Uri(
                scheme: next.scheme,
                host: next.host,
                port: next.hasPort ? next.port : null,
                path: next.path)
            .toString());
      } catch (_) {
        return result.withRedirects(history, '网站跳转到了不支持的地址，检测已停止。');
      }
      if (!visited.add(next.toString())) {
        return result.withRedirects(history, '网站在几个地址之间重复跳转，无法到达最终页面。');
      }
      history.add(result);
      current = next;
      onStage?.call('正在跟随网站跳转…');
    }
  }

  Future<SiteDiagnosticReport> _inspectOnce(Uri target,
      {required int proxyPort,
      int? apiPort,
      required Map<String, String> apiHeaders,
      void Function(String)? onStage}) async {
    final monitor = apiPort == null
        ? null
        : SiteRouteMonitor(apiPort, Map.unmodifiable(apiHeaders), target);
    _monitor = monitor;
    onStage?.call('准备记录本次访问路径…');
    if (!_cancelled) await monitor?.start();
    var summary = '诊断已取消';
    var failure = SiteFailure.cancelled;
    int? status;
    String? location;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    client.connectionFactory = (uri, proxyHost, port) async {
      if (_cancelled) throw const SocketException('Cancelled');
      final task =
          await Socket.startConnect(InternetAddress.loopbackIPv4, proxyPort);
      return ConnectionTask.fromSocket(task.socket.then((socket) {
        if (_cancelled) {
          socket.destroy();
          throw const SocketException('Cancelled');
        }
        monitor?.sourcePort = socket.port;
        return socket;
      }), task.cancel);
    };
    _client = client;
    final clock = Stopwatch()..start();
    try {
      if (!_cancelled) {
        onStage?.call('按当前规则访问网站…');
        final request = await client
            .openUrl('GET', target)
            .timeout(const Duration(seconds: 10));
        if (_cancelled) throw const SocketException('Cancelled');
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'SSRVPN-Diagnostic');
        final response =
            await request.close().timeout(const Duration(seconds: 10));
        status = response.statusCode;
        location = response.headers.value(HttpHeaders.locationHeader);
        failure =
            status >= 200 && status < 300 ? SiteFailure.none : SiteFailure.http;
        final elapsed = clock.elapsedMilliseconds;
        summary = status >= 200 && status < 300
            ? '访问成功 · HTTP $status · $elapsed ms'
            : status >= 300 && status < 400
                ? '收到重定向 · HTTP $status · $elapsed ms'
                : '收到 HTTP $status · $elapsed ms；响应可能来自网站或代理';
      }
    } on HandshakeException {
      failure = SiteFailure.tls;
      summary = 'TLS 验证失败';
    } on TimeoutException {
      failure = SiteFailure.timeout;
      summary = '访问超时';
    } on SocketException {
      failure = SiteFailure.connection;
      summary = '连接失败';
    } catch (_) {
      failure = SiteFailure.connection;
      summary = '访问失败';
    } finally {
      if (!_cancelled) {
        onStage?.call('核对匹配规则与实际出口…');
        // Keep the CONNECT tunnel alive until its route has been captured.
        try {
          await monitor?.capture().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      monitor?.close();
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
    return SiteDiagnosticReport(
        host: target.host,
        summary: _cancelled ? '诊断已取消' : summary,
        failure: _cancelled ? SiteFailure.cancelled : failure,
        statusCode: status,
        redirectLocation: location,
        route: _cancelled ? null : monitor?.evidence);
  }
}
