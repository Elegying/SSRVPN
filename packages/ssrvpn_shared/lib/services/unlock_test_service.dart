import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class UnlockTestResult {
  const UnlockTestResult({
    required this.id,
    required this.name,
    required this.url,
    required this.category,
    this.status = 'Unknown',
    this.detail,
    this.region,
    this.checkedAt,
  });

  final String id;
  final String name;
  final String url;
  final String category; // 'streaming' | 'ai' | 'other'
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
  bool get isFailed =>
      status == 'Failed' || status.startsWith('Failed');
  bool get isPending =>
      status == 'Pending' || status == 'Unknown' || status == 'Testing';

  UnlockTestResult copyWith({
    String? id,
    String? name,
    String? url,
    String? category,
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
      category: category ?? this.category,
      status: status ?? this.status,
      detail: clearDetail ? null : detail ?? this.detail,
      region: region ?? this.region,
      checkedAt: checkedAt ?? this.checkedAt,
    );
  }
}

class UnlockTestService {
  static const defaultItems = <UnlockTestResult>[
    // ── 流媒体 ──
    UnlockTestResult(id: 'netflix', name: 'Netflix', url: 'https://www.netflix.com/title/81215567', category: 'streaming'),
    UnlockTestResult(id: 'disney', name: 'Disney+', url: 'https://www.disneyplus.com/', category: 'streaming'),
    UnlockTestResult(id: 'youtube', name: 'YouTube Premium', url: 'https://www.youtube.com/premium', category: 'streaming'),
    UnlockTestResult(id: 'prime', name: 'Amazon Prime Video', url: 'https://www.primevideo.com/', category: 'streaming'),
    UnlockTestResult(id: 'max', name: 'HBO Max', url: 'https://www.max.com/', category: 'streaming'),
    UnlockTestResult(id: 'hulu', name: 'Hulu', url: 'https://www.hulu.com/', category: 'streaming'),
    UnlockTestResult(id: 'apple_tv', name: 'Apple TV+', url: 'https://tv.apple.com/', category: 'streaming'),
    UnlockTestResult(id: 'spotify', name: 'Spotify', url: 'https://www.spotify.com/', category: 'streaming'),
    UnlockTestResult(id: 'bbc', name: 'BBC iPlayer', url: 'https://www.bbc.co.uk/iplayer', category: 'streaming'),
    UnlockTestResult(id: 'paramount', name: 'Paramount+', url: 'https://www.paramountplus.com/', category: 'streaming'),
    UnlockTestResult(id: 'peacock', name: 'Peacock TV', url: 'https://www.peacocktv.com/', category: 'streaming'),
    UnlockTestResult(id: 'discovery', name: 'Discovery+', url: 'https://www.discoveryplus.com/', category: 'streaming'),
    UnlockTestResult(id: 'dazn', name: 'DAZN', url: 'https://www.dazn.com/', category: 'streaming'),
    UnlockTestResult(id: 'tiktok', name: 'TikTok', url: 'https://www.tiktok.com/', category: 'streaming'),
    UnlockTestResult(id: 'twitch', name: 'Twitch', url: 'https://www.twitch.tv/', category: 'streaming'),

    // ── AI 服务 ──
    UnlockTestResult(id: 'openai', name: 'OpenAI / ChatGPT', url: 'https://api.openai.com/v1/models', category: 'ai'),
    UnlockTestResult(id: 'chatgpt_web', name: 'ChatGPT', url: 'https://chat.openai.com/cdn-cgi/trace', category: 'ai'),
    UnlockTestResult(id: 'claude', name: 'Claude', url: 'https://api.anthropic.com/v1/messages', category: 'ai'),
    UnlockTestResult(id: 'gemini', name: 'Google Gemini', url: 'https://generativelanguage.googleapis.com/', category: 'ai'),
    UnlockTestResult(id: 'copilot', name: 'Microsoft Copilot', url: 'https://copilot.microsoft.com/', category: 'ai'),
    UnlockTestResult(id: 'perplexity', name: 'Perplexity', url: 'https://www.perplexity.ai/', category: 'ai'),
    UnlockTestResult(id: 'deepseek', name: 'DeepSeek', url: 'https://chat.deepseek.com/', category: 'ai'),
    UnlockTestResult(id: 'groq', name: 'Groq', url: 'https://api.groq.com/', category: 'ai'),
    UnlockTestResult(id: 'mistral', name: 'Mistral', url: 'https://api.mistral.ai/', category: 'ai'),
    UnlockTestResult(id: 'cohere', name: 'Cohere', url: 'https://api.cohere.ai/', category: 'ai'),

    // ── 开发 / 其他 ──
    UnlockTestResult(id: 'github', name: 'GitHub', url: 'https://github.com/', category: 'other'),
    UnlockTestResult(id: 'huggingface', name: 'Hugging Face', url: 'https://huggingface.co/', category: 'other'),
  ];

  Future<List<UnlockTestResult>> checkAll({
    required int proxyPort,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final results = await Future.wait(
      defaultItems.map(
        (item) => checkOne(id: item.id, proxyPort: proxyPort, timeout: timeout),
      ),
    );
    return results;
  }

  Future<UnlockTestResult> checkOne({
    required String id,
    required int proxyPort,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final item = defaultItems.firstWhere(
      (entry) => entry.id == id,
      orElse: () => UnlockTestResult(id: id, name: id, url: id, category: 'other', status: 'Unknown'),
    );

    final client = _proxyClient(proxyPort);
    try {
      final uri = Uri.parse(item.url);
      final useHead = _useHeadMethod(item.id);
      final response = await (useHead
          ? client.head(uri, headers: _headers()).timeout(timeout)
          : client.get(uri, headers: _headers()).timeout(timeout));

      final region = _extractRegion(response, uri.host);
      return item.copyWith(
        status: _statusFor(item.id, response),
        detail: _detailFor(response, item.id),
        region: region,
        checkedAt: DateTime.now(),
      );
    } on TimeoutException {
      return item.copyWith(
        status: 'Failed',
        detail: '请求超时',
        checkedAt: DateTime.now(),
      );
    } catch (e) {
      return item.copyWith(
        status: 'Failed',
        detail: e.toString().length > 120 ? e.toString().substring(0, 120) : e.toString(),
        checkedAt: DateTime.now(),
      );
    } finally {
      client.close();
    }
  }

  bool _useHeadMethod(String id) {
    return const {'prime', 'hulu', 'spotify', 'bbc', 'tiktok', 'twitch'}.contains(id);
  }

  Map<String, String> _headers() {
    return const {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept': 'text/html,application/json,*/*',
      'Accept-Language': 'en-US,en;q=0.9',
    };
  }

  http.Client _proxyClient(int proxyPort) {
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort; DIRECT';
    return IOClient(httpClient);
  }

  String _statusFor(String id, http.Response response) {
    final code = response.statusCode;
    final body = response.body.toLowerCase();

    // Netflix: check for redirect or region block
    if (id == 'netflix') {
      if (code == 200) return 'Available';
      if (code == 403 || code == 451) return 'No';
      if (code >= 300 && code < 400) {
        final location = response.headers['location'] ?? '';
        if (location.contains('title')) return 'Available';
        return 'No';
      }
    }

    // YouTube Premium
    if (id == 'youtube') {
      if (code == 200 && body.contains('premium')) return 'Available';
      if (code == 200) return 'Yes';
    }

    // OpenAI API
    if (id == 'openai') {
      if (code == 200 || code == 401) return 'Yes';
      if (code == 403) return 'No';
    }

    // Anthropic API
    if (id == 'claude') {
      if (code == 200 || code == 401 || code == 405) return 'Yes';
      if (code == 403) return 'No';
    }

    // Groq API
    if (id == 'groq') {
      if (code == 200 || code == 401) return 'Yes';
      if (code == 403) return 'No';
    }

    // Google APIs
    if (id == 'gemini') {
      if (code == 200 || code == 403) return 'Yes';
      if (code == 404) return 'No';
    }

    // BBC iPlayer
    if (id == 'bbc') {
      if (code == 200 && !body.contains('outside the uk')) return 'Yes';
      if (body.contains('outside the uk')) return 'No';
    }

    // Default
    if (code >= 200 && code < 400) return 'Yes';
    if (code == 403 || code == 451) return 'No';
    if (code == 407) return 'No';
    return 'Failed';
  }

  String? _extractRegion(http.Response response, String host) {
    final headers = response.headers;
    return headers['cf-ipcountry'] ??
        headers['x-country-code'] ??
        headers['x-region'] ??
        headers['x-geo-country'];
  }

  String _detailFor(http.Response response, String id) {
    final code = response.statusCode;
    final body = response.body.trim();

    // Try parse JSON for API services
    if (id == 'openai' && code == 401) {
      return 'HTTP 401 (API reachable)';
    }
    if (id == 'claude' && (code == 401 || code == 405)) {
      return 'HTTP $code (API reachable)';
    }

    if (body.isEmpty) return 'HTTP $code';
    if (body.length <= 120) return 'HTTP $code: $body';
    return 'HTTP $code: ${body.substring(0, 120)}...';
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
