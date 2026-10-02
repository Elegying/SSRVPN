import 'dart:async';
import 'dart:io';

/// A user-triggered HEAD request through the local proxy and current routing rules.
/// Does not fetch response bodies, follow redirects, or change connection state.
class SiteAccessDiagnostic {
  HttpClient? _client;
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
  }

  Future<String> run(Uri target, {required int proxyPort}) async {
    if (_cancelled) return '诊断已取消';
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    _client = client;
    final clock = Stopwatch()..start();
    try {
      final request = await client
          .openUrl('HEAD', target)
          .timeout(const Duration(seconds: 10));
      if (_cancelled) {
        request.abort();
        return '诊断已取消';
      }
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'SSRVPN-Diagnostic');
      final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
      final code = response.statusCode;
      if (_cancelled) return '诊断已取消';
      if (code >= 200 && code < 300) {
        return '访问成功 · HTTP $code · ${clock.elapsedMilliseconds} ms';
      }
      if (code >= 300 && code < 400) {
        return '网站返回重定向 · HTTP $code · ${clock.elapsedMilliseconds} ms（未继续访问跳转地址）';
      }
      if (code == 405 || code == 501) {
        return '已收到网站响应 · HTTP $code；网站不支持 HEAD 检测';
      }
      return '已收到网站响应 · HTTP $code · ${clock.elapsedMilliseconds} ms；请检查网站限制或登录要求';
    } on HandshakeException {
      return _cancelled ? '诊断已取消' : 'TLS 验证失败，请检查网站证书和系统时间';
    } on TimeoutException {
      return _cancelled ? '诊断已取消' : '访问超时，请检查当前节点和网站状态';
    } on SocketException {
      return _cancelled ? '诊断已取消' : '连接失败，请检查当前连接、节点和网站域名';
    } catch (_) {
      return _cancelled ? '诊断已取消' : '访问失败，请检查当前连接和网站地址';
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }
}
