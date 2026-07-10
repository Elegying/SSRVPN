import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/src/services/system_proxy_ownership.dart';

void main() {
  group('isOwnedMacProxy', () {
    test('accepts only the exact enabled endpoint SSRVPN recorded', () {
      expect(
        isOwnedMacProxy(
          enabled: true,
          server: '127.0.0.1',
          port: 7890,
          ownedHost: '127.0.0.1',
          ownedPort: 7890,
        ),
        isTrue,
      );
    });

    test('rejects another local proxy on a different port', () {
      expect(
        isOwnedMacProxy(
          enabled: true,
          server: '127.0.0.1',
          port: 8888,
          ownedHost: '127.0.0.1',
          ownedPort: 7890,
        ),
        isFalse,
      );
    });

    test('rejects disabled or externally changed proxy settings', () {
      expect(
        isOwnedMacProxy(
          enabled: false,
          server: '127.0.0.1',
          port: 7890,
          ownedHost: '127.0.0.1',
          ownedPort: 7890,
        ),
        isFalse,
      );
      expect(
        isOwnedMacProxy(
          enabled: true,
          server: 'localhost',
          port: 7890,
          ownedHost: '127.0.0.1',
          ownedPort: 7890,
        ),
        isFalse,
      );
    });

    test('rejects legacy state without ownership metadata', () {
      expect(
        isOwnedMacProxy(
          enabled: true,
          server: '127.0.0.1',
          port: 7890,
          ownedHost: null,
          ownedPort: null,
        ),
        isFalse,
      );
    });
  });
}
