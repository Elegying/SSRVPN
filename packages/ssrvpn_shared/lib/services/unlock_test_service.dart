import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

enum UnlockStatusRule {
  standard,
  netflix,
  youtubePremium,
  openAiApiReachable,
  apiReachable,
}

typedef UnlockTestClientFactory = http.Client Function(int proxyPort);

class UnlockTestCancelled implements Exception {
  const UnlockTestCancelled();
}

class UnlockTestCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const UnlockTestCancelled();
  }
}

class UnlockTestResult {
  const UnlockTestResult({
    required this.id,
    required this.name,
    required this.url,
    required this.category,
    String? officialUrl,
    this.statusRule = UnlockStatusRule.standard,
    this.status = 'Unknown',
    this.detail,
    this.region,
    this.checkedAt,
  }) : officialUrl = officialUrl ?? url;

  final String id;
  final String name;
  final String url;
  final String officialUrl;
  final String category; // 'streaming' | 'ai' | 'other'
  final UnlockStatusRule statusRule;
  final String status;
  final String? detail;
  final String? region;
  final DateTime? checkedAt;

  bool get isUnlocked =>
      status == 'Yes' ||
      status == 'Available' ||
      status == 'Unlocked' ||
      status == 'Originals Only';
  bool get isBlocked =>
      status == 'No' ||
      status == 'Blocked' ||
      status == 'Unsupported Country/Region' ||
      status == 'Disallowed ISP';
  bool get isReachable => status == 'Reachable';
  bool get isSuccessful => isUnlocked;
  bool get isInconclusive => status == 'Inconclusive';
  bool get isFailed => status == 'Failed' || status.startsWith('Failed');
  bool get isPending =>
      status == 'Pending' || status == 'Unknown' || status == 'Testing';

  String get displayStatusLabel {
    if (status == 'Testing') return '测试中';
    if (isUnlocked) return '支持';
    if (isReachable) return '可访问';
    if (isBlocked) return '不支持';
    if (isInconclusive) return '无法判断';
    if (isFailed) return '检测失败';
    return '待测试';
  }

  UnlockTestResult copyWith({
    String? id,
    String? name,
    String? url,
    String? officialUrl,
    String? category,
    UnlockStatusRule? statusRule,
    String? status,
    String? detail,
    String? region,
    DateTime? checkedAt,
    bool clearDetail = false,
  }) {
    return UnlockTestResult(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      officialUrl: officialUrl ?? this.officialUrl,
      category: category ?? this.category,
      statusRule: statusRule ?? this.statusRule,
      status: status ?? this.status,
      detail: clearDetail ? null : detail ?? this.detail,
      region: region ?? this.region,
      checkedAt: checkedAt ?? this.checkedAt,
    );
  }
}

class UnlockTestService {
  UnlockTestService({UnlockTestClientFactory? clientFactory})
      : _clientFactory = clientFactory ?? _createProxyClient;

  static const _maxConcurrentChecks = 4;
  static const _maxRedirects = 5;
  static const _maxResponseBytes = 768 * 1024;
  static const _maxRedirectBodyBytes = 8 * 1024;

  final UnlockTestClientFactory _clientFactory;

  static const defaultItems = <UnlockTestResult>[
    // ── 流媒体 ──
    UnlockTestResult(
        id: 'netflix',
        name: 'Netflix',
        url: 'https://www.netflix.com/title/81215567',
        category: 'streaming',
        statusRule: UnlockStatusRule.netflix),
    UnlockTestResult(
        id: 'disney',
        name: 'Disney+',
        url: 'https://www.disneyplus.com/',
        category: 'streaming'),
    UnlockTestResult(
        id: 'youtube',
        name: 'YouTube Premium',
        url: 'https://www.youtube.com/premium',
        category: 'streaming',
        statusRule: UnlockStatusRule.youtubePremium),
    UnlockTestResult(
        id: 'prime',
        name: 'Amazon Prime Video',
        url: 'https://www.primevideo.com/',
        category: 'streaming'),
    UnlockTestResult(
        id: 'max',
        name: 'HBO Max',
        url: 'https://www.max.com/',
        category: 'streaming'),
    UnlockTestResult(
        id: 'apple_tv',
        name: 'Apple TV+',
        url: 'https://tv.apple.com/',
        category: 'streaming'),
    UnlockTestResult(
        id: 'spotify',
        name: 'Spotify',
        url: 'https://www.spotify.com/',
        category: 'streaming'),
    UnlockTestResult(
        id: 'discovery',
        name: 'Discovery+',
        url: 'https://www.discoveryplus.com/',
        category: 'streaming'),
    UnlockTestResult(
        id: 'tiktok',
        name: 'TikTok',
        url: 'https://www.tiktok.com/',
        category: 'streaming'),

    // ── AI 服务 ──
    UnlockTestResult(
        id: 'chatgpt',
        name: 'ChatGPT',
        url: 'https://api.openai.com/v1/models',
        officialUrl: 'https://chatgpt.com/',
        category: 'ai',
        statusRule: UnlockStatusRule.openAiApiReachable),
    UnlockTestResult(
        id: 'claude',
        name: 'Claude',
        url: 'https://api.anthropic.com/v1/messages',
        officialUrl: 'https://claude.ai/',
        category: 'ai',
        statusRule: UnlockStatusRule.apiReachable),
    UnlockTestResult(
        id: 'gemini',
        name: 'Google Gemini',
        url: 'https://generativelanguage.googleapis.com/v1beta/models',
        officialUrl: 'https://gemini.google.com/',
        category: 'ai',
        statusRule: UnlockStatusRule.apiReachable),
    UnlockTestResult(
        id: 'copilot',
        name: 'Microsoft Copilot',
        url: 'https://copilot.microsoft.com/',
        category: 'ai'),
    UnlockTestResult(
        id: 'deepseek',
        name: 'DeepSeek',
        url: 'https://chat.deepseek.com/',
        category: 'ai'),

    // ── 开发 / 其他 ──
    UnlockTestResult(
        id: 'github',
        name: 'GitHub',
        url: 'https://github.com/',
        category: 'other'),
  ];

  Future<List<UnlockTestResult>> checkAll({
    required int proxyPort,
    Duration timeout = const Duration(seconds: 12),
    UnlockTestCancellation? cancellation,
  }) async {
    final results = <UnlockTestResult>[];
    for (var start = 0;
        start < defaultItems.length;
        start += _maxConcurrentChecks) {
      cancellation?.throwIfCancelled();
      final end = (start + _maxConcurrentChecks).clamp(
        0,
        defaultItems.length,
      );
      results.addAll(
        await Future.wait(
          defaultItems.sublist(start, end).map(
                (item) => checkOne(
                  id: item.id,
                  proxyPort: proxyPort,
                  timeout: timeout,
                  cancellation: cancellation,
                ),
              ),
        ),
      );
    }
    return results;
  }

  Future<UnlockTestResult> checkOne({
    required String id,
    required int proxyPort,
    Duration timeout = const Duration(seconds: 12),
    UnlockTestCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    UnlockTestResult? item;
    for (final candidate in defaultItems) {
      if (candidate.id == id) {
        item = candidate;
        break;
      }
    }
    if (item == null) {
      return UnlockTestResult(
        id: id,
        name: id,
        url: 'https://invalid.local/',
        category: 'other',
        status: 'Failed',
        detail: '检测项目不存在',
        checkedAt: DateTime.now(),
      );
    }

    final client = _clientFactory(proxyPort);
    try {
      final uri = Uri.parse(item.url);
      final request = _request(client, uri).timeout(timeout);
      final result = cancellation == null
          ? await request
          : await Future.any([
              request,
              cancellation.whenCancelled.then<_UnlockHttpResponse>((_) {
                client.close();
                throw const UnlockTestCancelled();
              }),
            ]);
      final status = _statusFor(item, result);

      return item.copyWith(
        status: status,
        detail: _detailFor(result, item, status),
        region: _extractRegion(result.response),
        checkedAt: DateTime.now(),
      );
    } on TimeoutException {
      return item.copyWith(
        status: 'Failed',
        detail: '请求超时',
        checkedAt: DateTime.now(),
      );
    } on UnlockTestCancelled {
      rethrow;
    } catch (e) {
      return item.copyWith(
        status: 'Failed',
        detail: e.toString().length > 120
            ? e.toString().substring(0, 120)
            : e.toString(),
        checkedAt: DateTime.now(),
      );
    } finally {
      client.close();
    }
  }

  Future<_UnlockHttpResponse> _request(http.Client client, Uri uri) async {
    var current = uri;
    for (var redirectCount = 0;
        redirectCount <= _maxRedirects;
        redirectCount++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(_headers());
      final streamed = await client.send(request);
      final location = streamed.headers['location'];

      if (_isRedirect(streamed.statusCode) && location != null) {
        await _readBody(streamed, limit: _maxRedirectBodyBytes);
        if (redirectCount == _maxRedirects) {
          throw StateError('重定向次数过多');
        }
        final next = current.resolve(location);
        if (next.scheme.toLowerCase() != 'https') {
          throw StateError('拒绝非 HTTPS 重定向');
        }
        current = next;
        continue;
      }

      final body = await _readBody(streamed, limit: _maxResponseBytes);
      return _UnlockHttpResponse(
        response: http.Response.bytes(
          body.bytes,
          streamed.statusCode,
          headers: streamed.headers,
          request: request,
          isRedirect: streamed.isRedirect,
          persistentConnection: streamed.persistentConnection,
          reasonPhrase: streamed.reasonPhrase,
        ),
        finalUri: current,
        bodyTruncated: body.truncated,
      );
    }
    throw StateError('重定向次数过多');
  }

  bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  Future<_BoundedBody> _readBody(
    http.StreamedResponse response, {
    required int limit,
  }) async {
    final bytes = <int>[];
    var truncated = false;
    await for (final chunk in response.stream) {
      final remaining = limit - bytes.length;
      if (remaining <= 0) {
        truncated = true;
        break;
      }
      if (chunk.length > remaining) {
        bytes.addAll(chunk.take(remaining));
        truncated = true;
        break;
      }
      bytes.addAll(chunk);
    }
    return _BoundedBody(bytes, truncated);
  }

  Map<String, String> _headers() {
    return const {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept': 'text/html,application/json,*/*',
      'Accept-Language': 'en-US,en;q=0.9',
    };
  }

  static http.Client _createProxyClient(int proxyPort) {
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    return IOClient(httpClient);
  }

  String _statusFor(UnlockTestResult item, _UnlockHttpResponse result) {
    final response = result.response;
    final code = response.statusCode;
    final body = response.body.toLowerCase();
    final expectedHost = Uri.parse(item.url).host.toLowerCase();
    final exactHostRequired =
        item.statusRule == UnlockStatusRule.apiReachable ||
            item.statusRule == UnlockStatusRule.openAiApiReachable;
    final expectedHostMatched = exactHostRequired
        ? result.finalUri.host.toLowerCase() == expectedHost
        : _isExpectedServiceHost(result.finalUri, _rootDomain(expectedHost));
    if (!expectedHostMatched) {
      return 'Inconclusive';
    }

    switch (item.statusRule) {
      case UnlockStatusRule.netflix:
        if (_containsRegionDenial(body)) return 'No';
        if (result.bodyTruncated) return 'Inconclusive';
        if (code == 200 &&
            _isExpectedServiceHost(result.finalUri, 'netflix.com') &&
            _containsNetflixTitleEvidence(result.finalUri, body)) {
          return 'Available';
        }
        return _fallbackStatus(code);
      case UnlockStatusRule.youtubePremium:
        if (_containsAny(body, const [
          'youtube premium is not available in your country',
          'youtube premium is not available in your region',
          'premium is not available in your country',
          'premium is not available in your region',
        ])) {
          return 'No';
        }
        if (_containsAmbiguousUnavailability(body)) return 'Inconclusive';
        if (result.bodyTruncated) return 'Inconclusive';
        if (code == 200 &&
            _isExpectedServiceHost(result.finalUri, 'youtube.com') &&
            body.contains('youtube premium') &&
            _containsAny(body, const [
              'get youtube premium',
              'try it free',
              'start your trial',
            ])) {
          return 'Available';
        }
        return _fallbackStatus(code, successStatus: 'Inconclusive');
      case UnlockStatusRule.openAiApiReachable:
        if (_containsRegionDenial(body)) return 'No';
        if (result.bodyTruncated) return 'Inconclusive';
        if (code == 401 && _containsOpenAiAuthEvidence(response)) {
          return 'Reachable';
        }
        return _fallbackStatus(code, successStatus: 'Inconclusive');
      case UnlockStatusRule.apiReachable:
        if (_containsRegionDenial(body)) return 'No';
        if (code == 200 ||
            code == 400 ||
            code == 401 ||
            code == 404 ||
            code == 405) {
          return 'Reachable';
        }
        if (code == 403 && _containsAuthenticationMarker(body)) {
          return 'Reachable';
        }
        return _fallbackStatus(code, successStatus: 'Inconclusive');
      case UnlockStatusRule.standard:
        return _fallbackStatus(code, successStatus: 'Reachable');
    }
  }

  bool _isExpectedServiceHost(Uri uri, String rootDomain) {
    final host = uri.host.toLowerCase();
    return host == rootDomain || host.endsWith('.$rootDomain');
  }

  String _rootDomain(String host) {
    final labels = host.toLowerCase().split('.');
    if (labels.length < 2) return host.toLowerCase();
    return labels.sublist(labels.length - 2).join('.');
  }

  String _fallbackStatus(int code, {String successStatus = 'Inconclusive'}) {
    if (code >= 200 && code < 300) return successStatus;
    if (code == 401 && successStatus == 'Reachable') return 'Reachable';
    if (code >= 500 || code == 407) return 'Failed';
    return 'Inconclusive';
  }

  bool _containsRegionDenial(String body) => _containsAny(body, const [
        'not available in your country',
        'not available in your region',
        'country is not supported',
        'region is not supported',
        'location is not supported',
        'unsupported country',
        'unsupported region',
        'unsupported_country_region_territory',
        'country, region, or territory not supported',
      ]);

  bool _containsOpenAiAuthEvidence(http.Response response) {
    final authenticate =
        response.headers['www-authenticate']?.toLowerCase() ?? '';
    final body = response.body.toLowerCase();
    return authenticate.contains('bearer') &&
        authenticate.contains('openai') &&
        body.contains('missing bearer authentication');
  }

  bool _containsNetflixTitleEvidence(Uri finalUri, String body) {
    final segments = finalUri.pathSegments;
    final titleIndex = segments.indexOf('title');
    if (titleIndex < 0 || titleIndex + 1 >= segments.length) return false;
    final titleId = segments[titleIndex + 1];
    final hasKnownMetadata = _containsAny(body, const [
      'property="og:title"',
      "property='og:title'",
      'application/ld+json',
      '"videoid"',
      '"titleid"',
    ]);
    return RegExp(r'^\d+$').hasMatch(titleId) &&
        body.contains(titleId) &&
        hasKnownMetadata;
  }

  bool _containsAmbiguousUnavailability(String body) =>
      body.contains('unavailable') || body.contains('not offered');

  bool _containsAuthenticationMarker(String body) => _containsAny(body, const [
        'api key',
        'authentication',
        'unauthorized',
        'permission denied',
        'missing x-api-key',
      ]);

  bool _containsAny(String value, List<String> markers) =>
      markers.any(value.contains);

  String? _extractRegion(http.Response response) {
    final headers = response.headers;
    return headers['cf-ipcountry'] ??
        headers['x-country-code'] ??
        headers['x-region'] ??
        headers['x-geo-country'];
  }

  String _detailFor(
    _UnlockHttpResponse result,
    UnlockTestResult item,
    String status,
  ) {
    final response = result.response;
    final code = response.statusCode;
    final truncated = result.bodyTruncated ? '（响应已截断）' : '';

    if (status == 'Available') {
      if (item.statusRule == UnlockStatusRule.netflix) {
        return 'HTTP $code，测试片页可访问；不代表完整地区片库$truncated';
      }
      return 'HTTP $code，页面提供 Premium 开通入口$truncated';
    }
    if (status == 'Reachable') {
      if (item.statusRule == UnlockStatusRule.openAiApiReachable) {
        return 'HTTP $code，OpenAI 官方 API 端点可达；未验证 ChatGPT 账号和地区使用权限$truncated';
      }
      if (item.statusRule == UnlockStatusRule.apiReachable) {
        return 'HTTP $code，API 端点可达；未验证账号和地区使用权限$truncated';
      }
      return 'HTTP $code，官网可访问；不代表账号、地区片库或播放权限$truncated';
    }
    if (status == 'No') {
      return 'HTTP $code，页面明确提示当前国家或地区不可用$truncated';
    }
    if (status == 'Inconclusive') {
      return 'HTTP $code，站点已响应，但现有证据不足以判断地区解锁$truncated';
    }
    return 'HTTP $code，检测请求失败$truncated';
  }

  Map<String, dynamic>? tryDecodeJson(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

class _UnlockHttpResponse {
  const _UnlockHttpResponse({
    required this.response,
    required this.finalUri,
    required this.bodyTruncated,
  });

  final http.Response response;
  final Uri finalUri;
  final bool bodyTruncated;
}

class _BoundedBody {
  const _BoundedBody(this.bytes, this.truncated);

  final List<int> bytes;
  final bool truncated;
}
