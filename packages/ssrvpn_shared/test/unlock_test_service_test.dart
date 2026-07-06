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
}
