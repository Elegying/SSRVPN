import 'dart:convert';

import 'package:ssrvpn_shared/services/subscription_text_decoder.dart';
import 'package:test/test.dart';

void main() {
  test('subscription bodies require valid UTF-8', () {
    expect(decodeSubscriptionUtf8(utf8.encode('中文订阅')), '中文订阅');
    expect(
      () => decodeSubscriptionUtf8(<int>[0xC3, 0x28]),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('订阅内容不是有效 UTF-8'),
        ),
      ),
    );
  });

  test('HTTP headers preserve legacy octets without replacement text', () {
    expect(decodeHttp1HeaderBytes(<int>[0x58, 0x3A, 0x20, 0xFF]), 'X: ÿ');
  });
}
