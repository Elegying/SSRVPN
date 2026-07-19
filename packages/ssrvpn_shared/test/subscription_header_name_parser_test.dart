import 'package:characters/characters.dart';
import 'package:ssrvpn_shared/services/subscription_header_name_parser.dart';
import 'package:test/test.dart';

void main() {
  group('SubscriptionHeaderNameParser', () {
    test('prefers a case-insensitive profile title', () {
      expect(
        SubscriptionHeaderNameParser.fromHeaders(
          const {'Profile-Title': 'Primary Profile'},
        ),
        'Primary Profile',
      );
    });

    test('extracts and decodes a store name', () {
      expect(
        SubscriptionHeaderNameParser.fromHeaders(
          const {'profile-title': 'upload=1; store-name="base64:5rWL6K+V"'},
        ),
        '测试',
      );
    });

    test('falls back to a percent-encoded content-disposition filename', () {
      expect(
        SubscriptionHeaderNameParser.fromHeaders(
          const {
            'content-disposition':
                "attachment; filename*=UTF-8''SSRVPN%20Profile.yaml",
          },
        ),
        'SSRVPN Profile.yaml',
      );
    });

    test('returns null when no usable name exists', () {
      expect(
        SubscriptionHeaderNameParser.fromHeaders(
          const {'profile-title': '\r\n'},
        ),
        isNull,
      );
    });

    test('removes control and bidirectional formatting characters', () {
      expect(
        SubscriptionHeaderNameParser.fromHeaders(
          const {
            'profile-title': 'Safe\u202Egpj.exe\u0000\t\nName\u007F\u2066',
          },
        ),
        'Safegpj.exe Name',
      );
    });

    test('compresses Unicode whitespace', () {
      expect(
        SubscriptionHeaderNameParser.fromHeaders(
          const {'profile-title': '  SSRVPN\u00A0\u3000 Profile  '},
        ),
        'SSRVPN Profile',
      );
    });

    test('limits names without splitting an emoji grapheme cluster', () {
      final name = '${'A' * 127}👨‍👩‍👧‍👦-trailing';
      final parsed = SubscriptionHeaderNameParser.fromHeaders(
        {'profile-title': name},
      );

      expect(parsed, '${'A' * 127}👨‍👩‍👧‍👦');
      expect(parsed!.characters.length, 128);
    });
  });
}
