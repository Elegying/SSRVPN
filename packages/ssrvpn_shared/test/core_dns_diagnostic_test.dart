import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/core_dns_diagnostic.dart';

void main() {
  late HttpServer server;
  late CoreDnsDiagnostic query;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    query = CoreDnsDiagnostic(timeout: const Duration(seconds: 2));
  });
  tearDown(() async {
    query.cancel();
    await server.close(force: true);
  });
  Future<String> run() => query.inspect('example.com',
      apiPort: server.port, headers: {'Authorization': 'Bearer secret'});
  test('queries both families with auth and evidence boundaries', () async {
    server.listen((request) async {
      expect(request.uri.path, '/dns/query');
      expect(request.uri.queryParameters['name'], 'example.com');
      expect(request.headers.value('Authorization'), 'Bearer secret');
      final a = request.uri.queryParameters['type'] == 'A';
      request.response.write(jsonEncode({
        'Status': 0,
        'Answer': [
          {'type': a ? 1 : 28, 'data': a ? '192.0.2.1' : '2001:db8::1'}
        ]
      }));
      await request.response.close();
    });
    final result = await run();
    expect(result, contains('192.0.2.1'));
    expect(result, contains('2001:db8::1'));
    expect(result, contains('独立查询'));
    expect(result, contains('未知'));
    expect(result, isNot(contains('secret')));
  });
  for (final sample in <(Object, String)>[
    ({'Status': 3}, 'NXDOMAIN'),
    ({'Status': 0}, 'NODATA'),
    ({'Status': 2}, 'DNS 状态 2'),
    ({'Status': 0, 'TC': true}, '不完整'),
    ({'Status': '0'}, '格式无效'),
    ({'Status': 16}, '格式无效'),
    ({'Status': 0, 'Answer': 'secret'}, '格式无效'),
    (
      {
        'Status': 0,
        'Answer': [null]
      },
      '格式无效'
    ),
    (
      {
        'Status': 0,
        'Answer': [
          {'type': 1, 'data': 'secret'}
        ]
      },
      '格式无效'
    ),
  ]) {
    test('DNS response ${sample.$1}', () async {
      server.listen((request) async {
        request.response.write(jsonEncode(sample.$1));
        await request.response.close();
      });
      expect(await run(), contains(sample.$2));
    });
  }
  for (final status in [302, 401, 403, 404, 405, 500]) {
    test('HTTP $status cannot leak body or follow redirects', () async {
      var count = 0;
      server.listen((request) async {
        count++;
        request.response.statusCode = status;
        request.response.headers
            .set('Location', 'http://127.0.0.1:${server.port}/secret');
        request.response.write('private-secret');
        await request.response.close();
      });
      expect(await run(), isNot(contains('private-secret')));
      expect(count, 2);
    });
  }
  test('response size is bounded', () async {
    server.listen((request) async {
      request.response.write('x' * 32769);
      await request.response.close();
    });
    expect(await run(), contains('响应过大'));
  });
  test('timeout bounds stalled response', () async {
    query = CoreDnsDiagnostic(timeout: const Duration(milliseconds: 50));
    server.listen((_) {});
    expect(await run(), contains('超时'));
  });
  test('cancel pending response cannot publish answers', () async {
    final arrived = Completer<void>();
    server.listen((_) {
      if (!arrived.isCompleted) arrived.complete();
    });
    final pending = run();
    await arrived.future;
    query.cancel();
    expect(await pending, 'DNS：诊断已取消');
    expect(await run(), 'DNS：诊断已取消');
  });
  test('invalid names never contact controller', () async {
    expect(await query.inspect('bad/name', apiPort: server.port, headers: {}),
        contains('域名无效'));
  });
}
