import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/src/services/system_proxy_ownership.dart';

const _ownedOverride = '<local>;localhost;127.*';

void main() {
  group('isOwnedWindowsProxyEndpoint', () {
    test('recognizes the enabled localhost endpoint despite support changes',
        () {
      expect(
        isOwnedWindowsProxyEndpoint(
          proxyEnable: 1,
          hasProxyServer: true,
          proxyServer: '127.0.0.1:7890',
          ownedProxyServer: '127.0.0.1:7890',
        ),
        isTrue,
      );
    });

    test('does not claim a disabled or replaced endpoint', () {
      expect(
        isOwnedWindowsProxyEndpoint(
          proxyEnable: 0,
          hasProxyServer: true,
          proxyServer: '127.0.0.1:7890',
          ownedProxyServer: '127.0.0.1:7890',
        ),
        isFalse,
      );
      expect(
        isOwnedWindowsProxyEndpoint(
          proxyEnable: 1,
          hasProxyServer: true,
          proxyServer: '127.0.0.1:8888',
          ownedProxyServer: '127.0.0.1:7890',
        ),
        isFalse,
      );
    });
  });

  group('isOwnedWindowsProxy', () {
    test('accepts only the exact enabled proxy endpoint SSRVPN recorded', () {
      expect(
        isOwnedWindowsProxy(
          proxyEnable: 1,
          hasProxyServer: true,
          proxyServer: '127.0.0.1:7890',
          ownedProxyServer: '127.0.0.1:7890',
          hasProxyOverride: true,
          proxyOverride: _ownedOverride,
          ownedProxyOverride: _ownedOverride,
          hasAutoConfigUrl: false,
          autoConfigUrl: '',
          hasAutoDetect: true,
          autoDetect: 0,
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
          hasProxyOverride: true,
          proxyOverride: _ownedOverride,
          ownedProxyOverride: _ownedOverride,
          hasAutoConfigUrl: false,
          autoConfigUrl: '',
          hasAutoDetect: true,
          autoDetect: 0,
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
          hasProxyOverride: true,
          proxyOverride: _ownedOverride,
          ownedProxyOverride: _ownedOverride,
          hasAutoConfigUrl: false,
          autoConfigUrl: '',
          hasAutoDetect: true,
          autoDetect: 0,
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
          hasProxyOverride: true,
          proxyOverride: _ownedOverride,
          ownedProxyOverride: _ownedOverride,
          hasAutoConfigUrl: false,
          autoConfigUrl: '',
          hasAutoDetect: true,
          autoDetect: 0,
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
          hasProxyOverride: true,
          proxyOverride: _ownedOverride,
          ownedProxyOverride: _ownedOverride,
          hasAutoConfigUrl: false,
          autoConfigUrl: '',
          hasAutoDetect: true,
          autoDetect: 0,
        ),
        isFalse,
      );
    });

    test('rejects changes to PAC, autodetect, or proxy bypass settings', () {
      bool owned({
        bool hasOverride = true,
        String override = _ownedOverride,
        bool hasPac = false,
        String pac = '',
        bool hasAutoDetect = true,
        int autoDetect = 0,
      }) =>
          isOwnedWindowsProxy(
            proxyEnable: 1,
            hasProxyServer: true,
            proxyServer: '127.0.0.1:7890',
            ownedProxyServer: '127.0.0.1:7890',
            hasProxyOverride: hasOverride,
            proxyOverride: override,
            ownedProxyOverride: _ownedOverride,
            hasAutoConfigUrl: hasPac,
            autoConfigUrl: pac,
            hasAutoDetect: hasAutoDetect,
            autoDetect: autoDetect,
          );

      expect(owned(override: '<local>;example.com'), isFalse);
      expect(
          owned(hasPac: true, pac: 'https://example.com/proxy.pac'), isFalse);
      expect(owned(autoDetect: 1), isFalse);
      expect(owned(hasAutoDetect: false), isFalse);
    });
  });
}
