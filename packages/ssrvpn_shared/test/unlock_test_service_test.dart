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
      'ChatGPT',
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

    expect(byId['prime']!.method, UnlockTestHttpMethod.head);
    expect(byId['spotify']!.method, UnlockTestHttpMethod.head);
    expect(byId['tiktok']!.method, UnlockTestHttpMethod.head);

    expect(byId['netflix']!.statusRule, UnlockStatusRule.netflix);
    expect(byId['youtube']!.statusRule, UnlockStatusRule.youtubePremium);
    expect(byId['claude']!.statusRule, UnlockStatusRule.apiReachable);
    expect(byId['gemini']!.statusRule, UnlockStatusRule.googleApi);
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
  });
}
