import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/src/services/system_proxy_ownership.dart';

void main() {
  group('isOwnedWindowsProxy', () {
    test('accepts only the exact enabled proxy endpoint SSRVPN recorded', () {
      expect(
        isOwnedWindowsProxy(
          proxyEnable: 1,
          hasProxyServer: true,
          proxyServer: '127.0.0.1:7890',
          ownedProxyServer: '127.0.0.1:7890',
        ),
        isTrue,
      );
    });

    test('rejects a disabled proxy even when the endpoint matches', () {
      expect(
        isOwnedWindowsProxy(
          proxyEnable: 0,
          hasProxyServer: true,
          proxyServer: '127.0.0.1:7890',
          ownedProxyServer: '127.0.0.1:7890',
        ),
        isFalse,
      );
    });

    test('rejects a missing ProxyServer registry value', () {
      expect(
        isOwnedWindowsProxy(
          proxyEnable: 1,
          hasProxyServer: false,
          proxyServer: '127.0.0.1:7890',
          ownedProxyServer: '127.0.0.1:7890',
        ),
        isFalse,
      );
    });

    test('rejects a proxy endpoint changed by the user or another app', () {
      expect(
        isOwnedWindowsProxy(
          proxyEnable: 1,
          hasProxyServer: true,
          proxyServer: '127.0.0.1:8888',
          ownedProxyServer: '127.0.0.1:7890',
        ),
        isFalse,
      );
    });

    test('rejects legacy backups without ownership metadata', () {
      expect(
        isOwnedWindowsProxy(
          proxyEnable: 1,
          hasProxyServer: true,
          proxyServer: '127.0.0.1:7890',
          ownedProxyServer: null,
        ),
        isFalse,
      );
    });
  });
}
