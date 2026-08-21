import 'package:ssrvpn_shared/utils/log_redactor.dart';
import 'package:test/test.dart';

void main() {
  test('redacts public IPv4 while retaining local endpoint diagnostics', () {
    final publicAddress = ['8', '8', '4', '4'].join('.');
    final sanitized = LogRedactor.sanitize(
      'egress=$publicAddress controller=127.0.0.1:9090',
    );

    expect(sanitized, isNot(contains(publicAddress)));
    expect(sanitized, contains('[public-ip-redacted]'));
    expect(sanitized, contains('127.0.0.1:9090'));
  });

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

  test('redacts quoted credential assignments without consuming later fields',
      () {
    final sanitized = LogRedactor.sanitize(
      '''password="alpha beta gamma" status=ready, token='delta epsilon'; apiSecret="zeta eta" node=usable''',
    );

    expect(sanitized, contains('password: ***'));
    expect(sanitized, contains('token: ***'));
    expect(sanitized, contains('apiSecret: ***'));
    expect(sanitized, contains('status=ready'));
    expect(sanitized, contains('node=usable'));
    expect(sanitized, isNot(contains('alpha beta gamma')));
    expect(sanitized, isNot(contains('delta epsilon')));
    expect(sanitized, isNot(contains('zeta eta')));
  });

  test('fails safely for an unterminated quoted credential', () {
    final sanitized = LogRedactor.sanitize(
      'token="secret value that never closes',
    );

    expect(sanitized, 'token: ***');
    expect(sanitized, isNot(contains('secret value')));
  });

  test('redacts quoted authorization values containing spaces', () {
    final sanitized = LogRedactor.sanitize(
      'authorization="Bearer alpha beta" status=ready',
    );

    expect(sanitized, contains('authorization: ***'));
    expect(sanitized, contains('status=ready'));
    expect(sanitized, isNot(contains('alpha beta')));
  });

  test('fails closed for unterminated quoted authorization values', () {
    for (final input in const [
      'authorization="Bearer alpha beta',
      "authorization='Basic dXNlcjpwYXNz extra",
      '{"authorization":"Bearer alpha beta',
      "{'authorization':'Token alpha beta",
    ]) {
      final sanitized = LogRedactor.sanitize(input);

      expect(sanitized, isNot(contains('alpha')));
      expect(sanitized, isNot(contains('beta')));
      expect(sanitized, isNot(contains('dXNlcjpwYXNz')));
      expect(sanitized, isNot(contains('extra')));
      expect(sanitized, contains('authorization: ***'));
    }
  });

  test('redacts multiline quoted credentials and preserves later fields', () {
    for (final input in const [
      'password="alpha\nbeta"\nstatus=ready',
      'authorization="Bearer alpha\r\nbeta"\r\nstatus=ready',
    ]) {
      final sanitized = LogRedactor.sanitize(input);

      expect(sanitized, isNot(contains('alpha')));
      expect(sanitized, isNot(contains('beta')));
      expect(sanitized, contains('status=ready'));
    }
  });

  test('redacts closed multiline JSON credentials and preserves later fields',
      () {
    const cases = {
      '{"password":"alpha\nbeta","status":"ready"}': '"status":"ready"',
      '{"authorization":"Bearer alpha\r\nbeta","status":"ready"}':
          '"status":"ready"',
      "{'password':'alpha\r\nbeta','status':'ready'}": "'status':'ready'",
      "{'authorization':'Token alpha\nbeta','status':'ready'}":
          "'status':'ready'",
    };
    for (final entry in cases.entries) {
      final sanitized = LogRedactor.sanitize(entry.key);

      expect(sanitized, isNot(contains('alpha')));
      expect(sanitized, isNot(contains('beta')));
      expect(sanitized, contains(entry.value));
    }
  });

  test('fails closed for unterminated multiline quoted credentials', () {
    for (final input in const [
      'password="alpha\nbeta',
      'authorization="Bearer alpha\r\nbeta',
    ]) {
      final sanitized = LogRedactor.sanitize(input);

      expect(sanitized, isNot(contains('alpha')));
      expect(sanitized, isNot(contains('beta')));
      expect(sanitized, contains('***'));
    }
  });

  test('redacts YAML block credentials without consuming dedented fields', () {
    for (final input in const [
      'password: |-\n  alpha\n  beta\nstatus: ready',
      'authorization: >+\r\n  Bearer alpha\r\n  beta\r\nstatus: ready',
    ]) {
      final sanitized = LogRedactor.sanitize(input);

      expect(sanitized, isNot(contains('alpha')));
      expect(sanitized, isNot(contains('beta')));
      expect(sanitized, contains('status: ready'));
    }
  });

  test('redacts escaped quotes inside credential values', () {
    final sanitized = LogRedactor.sanitize(
      r'''password="alpha\"beta gamma" status=ready''',
    );

    expect(sanitized, contains('password: ***'));
    expect(sanitized, contains('status=ready'));
    expect(sanitized, isNot(contains('beta gamma')));
  });

  test('fails safely for an unterminated JSON credential', () {
    final sanitized = LogRedactor.sanitize(
      '{"token":"json secret value that never closes',
    );

    expect(sanitized, contains('token: ***'));
    expect(sanitized, isNot(contains('json secret value')));
  });

  test('redacts escaped quotes inside JSON credential values', () {
    final sanitized = LogRedactor.sanitize(
      r'''{"token":"alpha\" beta","status":"ready"}''',
    );

    expect(sanitized, contains('"status":"ready"'));
    expect(sanitized, isNot(contains('alpha')));
    expect(sanitized, isNot(contains(' beta')));
  });

  test('recognizes semicolons as credential assignment boundaries', () {
    final sanitized = LogRedactor.sanitize(
      'status=x;password="alpha beta";node=ready',
    );

    expect(sanitized, contains('status=x'));
    expect(sanitized, contains('password: ***'));
    expect(sanitized, contains('node=ready'));
    expect(sanitized, isNot(contains('alpha beta')));
  });

  test('redacts public IPv6 while preserving useful local and reserved ranges',
      () {
    final sanitized = LogRedactor.sanitize(
      'egress=[2606:4700:4700::1111]:443 alternate=2404:6800:4005:80a::200e '
      'loopback=::1 link=fe80::1234 private=fd12:3456::1 docs=2001:db8::1',
    );

    expect(sanitized, isNot(contains('2606:4700:4700::1111')));
    expect(sanitized, isNot(contains('2404:6800:4005:80a::200e')));
    expect(sanitized, contains('[public-ip-redacted]:443'));
    expect(sanitized, contains('::1'));
    expect(sanitized, contains('fe80::1234'));
    expect(sanitized, contains('fd12:3456::1'));
    expect(sanitized, contains('2001:db8::1'));
  });

  test('redacts a public IPv6 address before trailing punctuation', () {
    final sanitized = LogRedactor.sanitize('egress=2001:4860:4860::8888.');

    expect(sanitized, 'egress=[public-ip-redacted].');
  });

  test('redacts credentials embedded in URLs', () {
    final sanitized = LogRedactor.sanitize(
      'GET https://user:pass@example.com/path?token=tok&access_token=access#api_key=key',
    );

    expect(sanitized, contains('https://example.com/***'));
    expect(sanitized, isNot(contains('user:pass')));
    expect(sanitized, isNot(contains('/path')));
    expect(sanitized, isNot(contains('access_token')));
  });

  test('redacts HTTP URL paths and fragments while retaining the origin', () {
    final sanitized = LogRedactor.sanitize(
      'request failed for '
      'https://api.example.com/client/private-token/refresh#session-secret',
    );

    expect(sanitized, contains('https://api.example.com/***'));
    expect(sanitized, isNot(contains('private-token')));
    expect(sanitized, isNot(contains('session-secret')));
  });

  test('retains explicit ports and brackets IPv6 origins', () {
    final sanitized = LogRedactor.sanitize(
      'ipv4=https://127.0.0.1:9090/version '
      'ipv6=http://[::1]:9090/connections',
    );

    expect(sanitized, contains('https://127.0.0.1:9090/***'));
    expect(sanitized, contains('http://[::1]:9090/***'));
    expect(sanitized, isNot(contains('/version')));
    expect(sanitized, isNot(contains('/connections')));
  });

  test('does not rewrite ordinary non-URL diagnostic text', () {
    const message = 'core ready route=/connections status=healthy';

    expect(LogRedactor.sanitize(message), message);
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

  test('sanitizes URLs embedded in display errors without exposing paths', () {
    final sanitized = LogRedactor.sanitizeForDisplay(
      'request failed for '
      'https://user:password@sub.example.com/private-path-token?token=secret',
    );

    expect(sanitized, contains('https://sub.example.com/***'));
    expect(sanitized, isNot(contains('password')));
    expect(sanitized, isNot(contains('private-path-token')));
    expect(sanitized, isNot(contains('secret')));
  });

  test('redacts local account names while preserving useful file context', () {
    final sanitized = LogRedactor.sanitizeForDisplay(
      'macOS /Users/alice/Library/App/app.dart:42 '
      r'Windows C:\Users\bob\AppData\Local\SSRVPN\ssrvpn.log '
      'Linux /home/carol/.config/ssrvpn/config.yaml',
    );

    expect(sanitized, contains('/Users/***/Library/App/app.dart:42'));
    expect(
        sanitized, contains(r'C:\Users\***\AppData\Local\SSRVPN\ssrvpn.log'));
    expect(sanitized, contains('/home/***/.config/ssrvpn/config.yaml'));
    expect(sanitized, isNot(contains('alice')));
    expect(sanitized, isNot(contains('bob')));
    expect(sanitized, isNot(contains('carol')));
  });

  test('redacts local account names containing spaces and unicode', () {
    final sanitized = LogRedactor.sanitizeForDisplay(
      'macOS /Users/张 三😀/Library/Application Support/SSRVPN/app.log '
      r'Windows C:\Users\李 四😀\AppData\Local\SSRVPN\ssrvpn.log '
      'Linux /home/测试 用户😀/.config/ssrvpn/config.yaml',
    );

    expect(
      sanitized,
      contains('/Users/***/Library/Application Support/SSRVPN/app.log'),
    );
    expect(
      sanitized,
      contains(r'C:\Users\***\AppData\Local\SSRVPN\ssrvpn.log'),
    );
    expect(
      sanitized,
      contains('/home/***/.config/ssrvpn/config.yaml'),
    );
    expect(sanitized, isNot(contains('张 三😀')));
    expect(sanitized, isNot(contains('李 四😀')));
    expect(sanitized, isNot(contains('测试 用户😀')));
  });

  test('redacts a home directory even without a descendant path', () {
    expect(
      LogRedactor.sanitizeForDisplay('/Users/private account'),
      '/Users/***',
    );
    expect(
      LogRedactor.sanitizeForDisplay(r'C:\Users\private account'),
      r'C:\Users\***',
    );
  });

  test('bounds hostile log lines before applying redaction regexes', () {
    final sanitized = LogRedactor.sanitize(
      '${'x' * (LogRedactor.maxInputCharacters * 2)} token=secret',
    );

    expect(
      sanitized.length,
      lessThanOrEqualTo(LogRedactor.maxInputCharacters + 32),
    );
    expect(sanitized, endsWith('... log entry truncated ...'));
  });
}
