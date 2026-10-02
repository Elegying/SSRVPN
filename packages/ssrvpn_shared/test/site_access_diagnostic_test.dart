import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/site_access_diagnostic.dart';

void main() {
  test('proxy-generated 502 is not reported as a response from the website',
      () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    proxy.listen((request) {
      request.response.statusCode = 502;
      request.response.close();
    });
    final result = await SiteAccessDiagnostic()
        .run(Uri.parse('http://example.com'), proxyPort: proxy.port);
    expect(result, contains('502'));
    expect(result, contains('网站或代理'));
    expect(result, isNot(contains('已收到网站响应')));
    expect(result, isNot(contains('访问成功')));
  });
  test(
      'uses the local proxy, GET, refuses private redirects, never consumes website body',
      () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final observed = Completer<HttpRequest>();
    proxy.listen((request) {
      observed.complete(request);
      request.response.statusCode = 302;
      request.response.headers.set('location', 'http://127.0.0.1/private');
      request.response.close();
    });
    final diagnostic = SiteAccessDiagnostic();
    final result = await diagnostic.run(Uri.parse('http://example.com/path'),
        proxyPort: proxy.port);
    final request = await observed.future;
    expect(request.method, 'GET');
    expect(request.uri.host, 'example.com');
    expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
    expect(result, contains('重定向'));
    expect(result, contains('302'));
    await proxy.close(force: true);
  });
  test('GET avoids HEAD-only 404 and follows redirects to the final result',
      () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    final seen = <Uri>[];
    proxy.listen((request) {
      seen.add(request.uri);
      if (request.method == 'HEAD') {
        request.response.statusCode = 404;
      } else if (request.uri.path == '/start') {
        request.response.statusCode = 301;
        request.response.headers
            .set('location', 'http://other.example/home.htm?lang=zh');
      } else {
        request.response.statusCode = 200;
      }
      request.response.close();
    });
    final report = await SiteAccessDiagnostic()
        .inspect(Uri.parse('http://example.com/start'), proxyPort: proxy.port);
    expect(report.succeeded, isTrue);
    expect(report.verdict, '可以访问');
    expect(report.host, 'other.example');
    expect(report.redirects.single.statusCode, 301);
    expect(seen.last.query, 'lang=zh');
  });
  for (final mode in ['loop', 'limit', 'missing', 'private', 'error']) {
    test('redirect $mode never becomes a false success', () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      var calls = 0;
      proxy.listen((request) {
        calls++;
        request.response.statusCode = mode == 'error' && calls > 1 ? 404 : 302;
        if (mode != 'missing') {
          request.response.headers.set(
              'location',
              switch (mode) {
                'loop' => '/start',
                'private' => 'http://127.0.0.1/private',
                _ => '/next$calls',
              });
        }
        request.response.close();
      });
      final report = await SiteAccessDiagnostic().inspect(
          Uri.parse('http://example.com/start'),
          proxyPort: proxy.port);
      expect(report.succeeded, isFalse);
      expect(
          calls,
          mode == 'limit'
              ? 6
              : mode == 'error'
                  ? 2
                  : 1);
      expect(report.verdict, mode == 'error' ? '没有找到这个页面' : '无法完成网站跳转');
    });
  }
  test('cancellation closes a pending network request without exposing URL',
      () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<void>();
    proxy.listen((request) {
      received.complete();
    });
    final diagnostic = SiteAccessDiagnostic();
    final pending = diagnostic.run(Uri.parse('http://example.com/path'),
        proxyPort: proxy.port);
    await received.future;
    diagnostic.cancel();
    expect(await pending.timeout(const Duration(seconds: 2)), '诊断已取消');
    await proxy.close(force: true);
  });
}
