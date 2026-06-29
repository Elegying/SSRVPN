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
}
