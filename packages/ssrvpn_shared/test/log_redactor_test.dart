import 'package:ssrvpn_shared/utils/log_redactor.dart';
import 'package:test/test.dart';

void main() {
  test('redacts common credential forms', () {
    final sanitized = LogRedactor.sanitize(
      'secret=abc password: p@ss token=tok Bearer raw apiSecret="hidden"',
    );

    expect(sanitized, contains('secret: ***'));
    expect(sanitized, contains('password: ***'));
    expect(sanitized, contains('token: ***'));
    expect(sanitized, contains('Bearer ***'));
    expect(sanitized, contains('apiSecret: ***'));
    expect(sanitized, isNot(contains('abc')));
    expect(sanitized, isNot(contains('p@ss')));
    expect(sanitized, isNot(contains('hidden')));
  });

  test('redacts credentials embedded in URLs', () {
    final sanitized = LogRedactor.sanitize(
      'GET https://user:pass@example.com/path?token=tok&access_token=access#api_key=key',
    );

    expect(sanitized, contains('https://***:***@example.com/path'));
    expect(sanitized, contains('token=***'));
    expect(sanitized, contains('access_token=***'));
    expect(sanitized, contains('api_key=***'));
    expect(sanitized, isNot(contains('user:pass')));
    expect(sanitized, isNot(contains('access#')));
  });

  test('redacts non-standard authorization header forms', () {
    final sanitized = LogRedactor.sanitize(
      'Authorization: Token abc, authorization=Basic basic123; authorization: ApiKey key123',
    );

    expect(sanitized, contains('Authorization: Token ***'));
    expect(sanitized, contains('authorization: Basic ***'));
    expect(sanitized, contains('authorization: ApiKey ***'));
    expect(sanitized, isNot(contains('abc')));
    expect(sanitized, isNot(contains('basic123')));
    expect(sanitized, isNot(contains('key123')));
  });

  test('redacts JSON-style credential fields', () {
    final sanitized = LogRedactor.sanitize(
      '{"token":"tok","Authorization":"Bearer abc","refresh_token":"refresh"}',
    );

    expect(sanitized, contains('"token":"***"'));
    expect(sanitized, contains('"Authorization":"Bearer ***"'));
    expect(sanitized, contains('"refresh_token":"***"'));
    expect(sanitized, isNot(contains('"tok"')));
    expect(sanitized, isNot(contains('"refresh"')));
  });

  test('redacts proxy node links', () {
    final sanitized = LogRedactor.sanitize(
      'ssr://encoded-secret trojan://password@example.com:443 anytls://token@host',
    );

    expect(sanitized, contains('ssr://***'));
    expect(sanitized, contains('trojan://***'));
    expect(sanitized, contains('anytls://***'));
    expect(sanitized, isNot(contains('encoded-secret')));
    expect(sanitized, isNot(contains('password@example.com')));
    expect(sanitized, isNot(contains('token@host')));
  });

  test('formats subscription urls for display without credentials', () {
    expect(
      LogRedactor.subscriptionUrlForDisplay(
        'https://sub.example.com/api/v1/client/subscribe?token=secret',
      ),
      'https://sub.example.com/***',
    );
    expect(
      LogRedactor.subscriptionUrlForDisplay('ssr://encoded-secret'),
      'ssr://***',
    );
  });
}
