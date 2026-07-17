import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/src/services/system_proxy_ownership.dart';

const _ownedOverride = '<local>;localhost;127.*';

const _original = WindowsProxyState(
  hasProxyEnable: true,
  proxyEnable: 0,
  hasProxyServer: true,
  proxyServer: 'proxy.example:8080',
  hasProxyOverride: true,
  proxyOverride: '<local>;example.test',
  hasAutoConfigUrl: true,
  autoConfigUrl: 'https://example.test/proxy.pac',
  hasAutoDetect: true,
  autoDetect: 1,
);

const _owned = WindowsProxyState(
  hasProxyEnable: true,
  proxyEnable: 1,
  hasProxyServer: true,
  proxyServer: '127.0.0.1:7890',
  hasProxyOverride: true,
  proxyOverride: _ownedOverride,
  hasAutoConfigUrl: false,
  autoConfigUrl: '',
  hasAutoDetect: true,
  autoDetect: 0,
);

void main() {
  group('Windows proxy transaction states', () {
    test('accepts every exact activation prefix', () {
      final prefixes = windowsProxyActivationPrefixes(
        original: _original,
        owned: _owned,
      );

      expect(prefixes, hasLength(6));
      for (final state in prefixes) {
        expect(
          isReachableWindowsProxyTransactionState(
            current: state,
            original: _original,
            owned: _owned,
            phase: WindowsProxyTransactionPhase.activation,
          ),
          isTrue,
        );
      }
    });

    test('rejects impossible Cartesian mixtures', () {
      const impossible = WindowsProxyState(
        hasProxyEnable: true,
        proxyEnable: 1,
        hasProxyServer: true,
        proxyServer: 'proxy.example:8080',
        hasProxyOverride: true,
        proxyOverride: _ownedOverride,
        hasAutoConfigUrl: true,
        autoConfigUrl: 'https://example.test/proxy.pac',
        hasAutoDetect: true,
        autoDetect: 0,
      );

      for (final phase in WindowsProxyTransactionPhase.values) {
        expect(
          isReachableWindowsProxyTransactionState(
            current: impossible,
            original: _original,
            owned: _owned,
            phase: phase,
          ),
          isFalse,
        );
      }
    });

    test('full restore accepts only states reachable from activation', () {
      final activation = windowsProxyActivationPrefixes(
        original: _original,
        owned: _owned,
      );
      final interrupted = activation[3].copyWith(proxyEnable: 0);

      expect(
        isReachableWindowsProxyTransactionState(
          current: interrupted,
          original: _original,
          owned: _owned,
          phase: WindowsProxyTransactionPhase.fullRestore,
        ),
        isTrue,
        reason:
            'disabled original proxies are made safe before support restore',
      );
    });

    test('endpoint restore ignores support fields but bounds endpoint states',
        () {
      final changedSupport = _owned.copyWith(
        proxyOverride: 'changed-by-user',
        autoConfigUrl: 'https://other.test/pac',
        hasAutoConfigUrl: true,
      );

      expect(
        isReachableWindowsProxyTransactionState(
          current: changedSupport.copyWith(proxyEnable: 0),
          original: _original,
          owned: _owned,
          phase: WindowsProxyTransactionPhase.endpointRestore,
        ),
        isTrue,
      );
      expect(
        isReachableWindowsProxyTransactionState(
          current: changedSupport.copyWith(proxyServer: 'foreign:9000'),
          original: _original,
          owned: _owned,
          phase: WindowsProxyTransactionPhase.endpointRestore,
        ),
        isFalse,
      );
    });

    test('missing ProxyEnable remains a recoverable exact registry state', () {
      final original = _original.copyWith(
        hasProxyEnable: false,
        proxyEnable: 0,
      );
      final activation = windowsProxyActivationPrefixes(
        original: original,
        owned: _owned,
      );

      expect(
          activation.take(5).every((state) => !state.hasProxyEnable), isTrue);
      expect(activation.last.hasProxyEnable, isTrue);
      expect(
        isReachableWindowsProxyTransactionState(
          current: activation[4],
          original: original,
          owned: _owned,
          phase: WindowsProxyTransactionPhase.activation,
        ),
        isTrue,
      );
      expect(
        isReachableWindowsProxyTransactionState(
          current: activation.last.copyWith(proxyEnable: 0),
          original: original,
          owned: _owned,
          phase: WindowsProxyTransactionPhase.fullRestore,
        ),
        isTrue,
      );
      expect(
        isReachableWindowsProxyTransactionState(
          current: original,
          original: original,
          owned: _owned,
          phase: WindowsProxyTransactionPhase.fullRestore,
        ),
        isTrue,
      );
    });
  });

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

    test('rejects changes to PAC, enabled autodetect, or proxy bypass', () {
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
      expect(owned(hasAutoDetect: false), isTrue);
    });
  });
}
