import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/services/unlock_test_service.dart';
import 'package:test/test.dart';

void main() {
  test('default unlock items omit removed services', () {
    final ids = UnlockTestService.defaultItems.map((item) => item.id).toSet();
    final names =
        UnlockTestService.defaultItems.map((item) => item.name).toSet();

    for (final id in const {
      'huggingface',
      'cohere',
      'groq',
      'mistral',
      'perplexity',
      'openai',
      'chatgpt_web',
      'twitch',
      'dazn',
      'peacock',
      'paramount',
      'bbc',
      'hulu',
    }) {
      expect(ids, isNot(contains(id)));
    }
    for (final name in const {
      'OpenAI / ChatGPT',
      'Hugging Face',
      'Cohere',
      'Groq',
      'Mistral',
      'Perplexity',
      'Twitch',
      'DAZN',
      'Peacock TV',
      'Paramount+',
      'BBC iPlayer',
      'Hulu',
    }) {
      expect(names, isNot(contains(name)));
    }
  });

  test('default unlock items carry request and status policies', () {
    final byId = {
      for (final item in UnlockTestService.defaultItems) item.id: item,
    };

    expect(byId['netflix']!.statusRule, UnlockStatusRule.netflix);
    expect(byId['youtube']!.statusRule, UnlockStatusRule.youtubePremium);
    expect(
      byId['chatgpt']!.statusRule,
      UnlockStatusRule.openAiApiReachable,
    );
    expect(byId['chatgpt']!.url, 'https://api.openai.com/v1/models');
    expect(byId['claude']!.statusRule, UnlockStatusRule.apiReachable);
    expect(byId['gemini']!.statusRule, UnlockStatusRule.apiReachable);
    expect(
      byId['gemini']!.url,
      'https://generativelanguage.googleapis.com/v1beta/models',
    );
  });

  test('default unlock items expose browser-friendly official URLs', () {
    const defaultUrlItem = UnlockTestResult(
      id: 'example',
      name: 'Example',
      url: 'https://example.com/check',
      category: 'other',
    );
    expect(defaultUrlItem.officialUrl, defaultUrlItem.url);

    for (final item in UnlockTestService.defaultItems) {
      final uri = Uri.parse(item.officialUrl);
      expect(uri.hasScheme, isTrue, reason: item.name);
      expect(['https', 'http'], contains(uri.scheme), reason: item.name);
      expect(uri.host, isNotEmpty, reason: item.name);
    }

    final byId = {
      for (final item in UnlockTestService.defaultItems) item.id: item,
    };

    expect(byId['claude']!.officialUrl, 'https://claude.ai/');
    expect(byId['gemini']!.officialUrl, 'https://gemini.google.com/');
    expect(byId['chatgpt']!.officialUrl, 'https://chatgpt.com/');
  });

  test('ChatGPT official authentication response proves reachability only',
      () async {
    final service = _serviceReturning(
      statusCode: 401,
      body: '''
{"error":{"message":"Missing bearer authentication in header","type":"invalid_request_error"}}
''',
      headers: {'www-authenticate': 'Bearer realm="OpenAI API"'},
    );

    final result = await service.checkOne(id: 'chatgpt', proxyPort: 7890);

    expect(result.status, 'Reachable');
    expect(result.displayStatusLabel, '可访问');
    expect(result.isUnlocked, isFalse);
    expect(result.detail, contains('未验证 ChatGPT'));
  });

  test('ChatGPT ambiguous 401 response is never reported as reachable',
      () async {
    final service = _serviceReturning(
      statusCode: 401,
      body: 'Unauthorized',
    );

    final result = await service.checkOne(id: 'chatgpt', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isUnlocked, isFalse);
    expect(result.isReachable, isFalse);
  });

  test('ChatGPT generic success and Cloudflare challenge stay inconclusive',
      () async {
    for (final response in const [
      (200, '<html>ChatGPT</html>'),
      (403, '<html>Cloudflare security challenge</html>'),
    ]) {
      final service = _serviceReturning(
        statusCode: response.$1,
        body: response.$2,
      );

      final result = await service.checkOne(id: 'chatgpt', proxyPort: 7890);

      expect(result.status, 'Inconclusive', reason: 'HTTP ${response.$1}');
      expect(result.isUnlocked, isFalse);
      expect(result.isReachable, isFalse);
    }
  });

  test('ChatGPT evidence on a non-OpenAI redirect stays inconclusive',
      () async {
    final service = UnlockTestService(
      clientFactory: (_) => MockClient((request) async {
        if (request.url.host == 'api.openai.com') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://example.com/v1/models'},
            request: request,
          );
        }
        return http.Response(
          '{"error":{"message":"Missing bearer authentication in header"}}',
          401,
          headers: {'www-authenticate': 'Bearer realm="OpenAI API"'},
          request: request,
        );
      }),
    );

    final result = await service.checkOne(id: 'chatgpt', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isReachable, isFalse);
  });

  test('truncated ChatGPT authentication evidence stays inconclusive',
      () async {
    final service = _serviceReturning(
      statusCode: 401,
      body: '{"error":{"message":"Missing bearer authentication in header"}}'
          '${List.filled(800 * 1024, 'x').join()}',
      headers: {'www-authenticate': 'Bearer realm="OpenAI API"'},
    );

    final result = await service.checkOne(id: 'chatgpt', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isReachable, isFalse);
    expect(result.detail, contains('响应已截断'));
  });

  test('ChatGPT explicit unsupported-country response is blocked', () async {
    final service = _serviceReturning(
      statusCode: 403,
      body: '''
{"error":{"code":"unsupported_country_region_territory","message":"Country, region, or territory not supported"}}
''',
    );

    final result = await service.checkOne(id: 'chatgpt', proxyPort: 7890);

    expect(result.status, 'No');
    expect(result.displayStatusLabel, '不支持');
  });

  test('generic website reachability is not reported as geo-unlocked',
      () async {
    final service = _serviceReturning(statusCode: 200, body: '<html>OK</html>');

    final result = await service.checkOne(id: 'github', proxyPort: 7890);

    expect(result.status, 'Reachable');
    expect(result.isReachable, isTrue);
    expect(result.isUnlocked, isFalse);
    expect(result.detail, contains('不代表'));
  });

  test('YouTube explicit country denial wins over Premium keywords', () async {
    final service = _serviceReturning(
      statusCode: 200,
      body: '<title>YouTube Premium is not available in your country</title>',
    );

    final result = await service.checkOne(id: 'youtube', proxyPort: 7890);

    expect(result.status, 'No');
    expect(result.isBlocked, isTrue);
  });

  test('YouTube ambiguous unavailability never reports Premium support',
      () async {
    final service = _serviceReturning(
      statusCode: 200,
      body:
          '<main>Get YouTube Premium. This offer is temporarily unavailable.</main>',
    );

    final result = await service.checkOne(id: 'youtube', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isUnlocked, isFalse);
  });

  test('Netflix unknown title-page markup remains inconclusive', () async {
    final service = _serviceReturning(
      statusCode: 200,
      body: '<html><main>Official page layout changed</main></html>',
    );

    final result = await service.checkOne(id: 'netflix', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isUnlocked, isFalse);
  });

  test('Netflix title id without known content metadata is inconclusive',
      () async {
    final service = _serviceReturning(
      statusCode: 200,
      body: '<html><main>81215567</main></html>',
    );

    final result = await service.checkOne(id: 'netflix', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isUnlocked, isFalse);
  });

  test('generic forbidden response remains inconclusive', () async {
    final service = _serviceReturning(statusCode: 403, body: 'Forbidden');

    final result = await service.checkOne(id: 'disney', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isInconclusive, isTrue);
  });

  test('API authentication response proves reachability, not unlock', () async {
    final service = _serviceReturning(
      statusCode: 403,
      body:
          '{"error":{"message":"API key not valid. Please pass a valid API key."}}',
      headers: {'content-type': 'application/json'},
    );

    final result = await service.checkOne(id: 'gemini', proxyPort: 7890);

    expect(result.status, 'Reachable');
    expect(result.isReachable, isTrue);
    expect(result.isUnlocked, isFalse);
  });

  test('requests use bounded GET and follow HTTPS redirects', () async {
    final methods = <String>[];
    final service = UnlockTestService(
      clientFactory: (_) => MockClient((request) async {
        methods.add(request.method);
        if (request.url.path == '/title/81215567') {
          return http.Response(
            '',
            302,
            headers: {
              'location': 'https://www.netflix.com/sg/title/81215567',
            },
            request: request,
          );
        }
        return http.Response(
          '<html><meta property="og:title" content="Netflix title 81215567"></html>',
          200,
          headers: {'cf-ipcountry': 'SG'},
          request: request,
        );
      }),
    );

    final result = await service.checkOne(id: 'netflix', proxyPort: 7890);

    expect(methods, ['GET', 'GET']);
    expect(result.status, 'Available');
    expect(result.region, 'SG');
  });

  test('Netflix evidence on a non-Netflix redirect stays inconclusive',
      () async {
    final service = UnlockTestService(
      clientFactory: (_) => MockClient((request) async {
        if (request.url.host == 'www.netflix.com') {
          return http.Response(
            '',
            302,
            headers: {
              'location': 'https://example.com/title/81215567',
            },
            request: request,
          );
        }
        return http.Response(
          '<meta property="og:title" content="Netflix title 81215567">',
          200,
          request: request,
        );
      }),
    );

    final result = await service.checkOne(id: 'netflix', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isUnlocked, isFalse);
  });

  test('YouTube evidence on a non-YouTube redirect stays inconclusive',
      () async {
    final service = UnlockTestService(
      clientFactory: (_) => MockClient((request) async {
        if (request.url.host == 'www.youtube.com') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://example.com/premium'},
            request: request,
          );
        }
        return http.Response(
          '<main>Get YouTube Premium. Start your trial.</main>',
          200,
          request: request,
        );
      }),
    );

    final result = await service.checkOne(id: 'youtube', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isUnlocked, isFalse);
  });

  test('API reachability on an unrelated redirect host is inconclusive',
      () async {
    final service = UnlockTestService(
      clientFactory: (_) => MockClient((request) async {
        if (request.url.host == 'api.anthropic.com') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://example.com/login'},
            request: request,
          );
        }
        return http.Response('OK', 200, request: request);
      }),
    );

    final result = await service.checkOne(id: 'claude', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isReachable, isFalse);
  });

  test('Gemini API redirect to a googleapis sibling is inconclusive', () async {
    final service = UnlockTestService(
      clientFactory: (_) => MockClient((request) async {
        if (request.url.host == 'generativelanguage.googleapis.com') {
          return http.Response(
            '',
            302,
            headers: {
              'location': 'https://storage.googleapis.com/unrelated',
            },
            request: request,
          );
        }
        return http.Response('OK', 200, request: request);
      }),
    );

    final result = await service.checkOne(id: 'gemini', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isReachable, isFalse);
  });

  test('rejects redirects that downgrade HTTPS', () async {
    final service = UnlockTestService(
      clientFactory: (_) => MockClient(
        (request) async => http.Response(
          '',
          302,
          headers: {'location': 'http://example.com/intercepted'},
          request: request,
        ),
      ),
    );

    final result = await service.checkOne(id: 'github', proxyPort: 7890);

    expect(result.status, 'Failed');
    expect(result.detail, contains('HTTPS'));
  });

  test('unknown item fails without issuing a network request', () async {
    var requested = false;
    final service = UnlockTestService(
      clientFactory: (_) => MockClient((request) async {
        requested = true;
        return http.Response('unexpected', 200, request: request);
      }),
    );

    final result = await service.checkOne(id: 'missing', proxyPort: 7890);

    expect(requested, isFalse);
    expect(result.status, 'Failed');
    expect(result.detail, '检测项目不存在');
  });

  test('status labels distinguish evidence from uncertainty', () {
    const base = UnlockTestResult(
      id: 'example',
      name: 'Example',
      url: 'https://example.com/',
      category: 'other',
    );

    expect(base.copyWith(status: 'Available').displayStatusLabel, '支持');
    final reachable = base.copyWith(status: 'Reachable');
    expect(reachable.displayStatusLabel, '可访问');
    expect(reachable.isSuccessful, isFalse);
    expect(base.copyWith(status: 'No').displayStatusLabel, '不支持');
    expect(base.copyWith(status: 'Inconclusive').displayStatusLabel, '无法判断');
    expect(base.copyWith(status: 'Failed').displayStatusLabel, '检测失败');
    expect(base.copyWith(status: 'Unknown').displayStatusLabel, '待测试');
  });

  test('response bodies are capped before classification', () async {
    final service = _serviceReturning(
      statusCode: 200,
      body: List.filled(800 * 1024, 'x').join(),
    );

    final result = await service.checkOne(id: 'github', proxyPort: 7890);

    expect(result.status, 'Reachable');
    expect(result.detail, contains('响应已截断'));
  });

  test('truncated Netflix evidence never reports support', () async {
    final service = _serviceReturning(
      statusCode: 200,
      body: '<meta property="og:title" content="81215567">'
          '${List.filled(800 * 1024, 'x').join()}',
    );

    final result = await service.checkOne(id: 'netflix', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isUnlocked, isFalse);
  });

  test('truncated YouTube CTA never reports Premium support', () async {
    final service = _serviceReturning(
      statusCode: 200,
      body: '<main>Get YouTube Premium. Start your trial.</main>'
          '${List.filled(800 * 1024, 'x').join()}',
    );

    final result = await service.checkOne(id: 'youtube', proxyPort: 7890);

    expect(result.status, 'Inconclusive');
    expect(result.isUnlocked, isFalse);
  });

  test('full audit limits concurrent requests', () async {
    var active = 0;
    var maxActive = 0;
    final service = UnlockTestService(
      clientFactory: (_) => MockClient((request) async {
        active += 1;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active -= 1;
        return http.Response('OK', 200, request: request);
      }),
    );

    final results = await service.checkAll(proxyPort: 7890);

    expect(results, hasLength(UnlockTestService.defaultItems.length));
    expect(maxActive, lessThanOrEqualTo(4));
  });

  test('full audit cancellation closes active requests immediately', () async {
    final clients = <_StalledClient>[];
    final service = UnlockTestService(
      clientFactory: (_) {
        final client = _StalledClient();
        clients.add(client);
        return client;
      },
    );
    final cancellation = UnlockTestCancellation();

    final audit = service.checkAll(
      proxyPort: 7890,
      timeout: const Duration(minutes: 1),
      cancellation: cancellation,
    );
    await Future<void>.delayed(Duration.zero);
    cancellation.cancel();

    await expectLater(audit, throwsA(isA<UnlockTestCancelled>()));
    expect(clients, hasLength(4));
    expect(clients.every((client) => client.closed), isTrue);
  });
}

class _StalledClient extends http.BaseClient {
  final Completer<http.StreamedResponse> _response = Completer();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _response.future;

  @override
  void close() {
    closed = true;
    if (!_response.isCompleted) {
      _response.completeError(const UnlockTestCancelled());
    }
  }
}

UnlockTestService _serviceReturning({
  required int statusCode,
  required String body,
  Map<String, String> headers = const {},
}) {
  return UnlockTestService(
    clientFactory: (_) => MockClient(
      (request) async => http.Response(
        body,
        statusCode,
        headers: headers,
        request: request,
      ),
    ),
  );
}
