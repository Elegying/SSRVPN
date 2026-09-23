import 'dart:convert';

/// Transport fields shared by URI import, YAML import and local node editing.
/// Invalid entries must be filtered before a single bad proxy can prevent the
/// core from loading the complete subscription. Unknown optional keys are kept.
class ProxyTransportValidation {
  // All three pinned cores use sing-shadowsocks2 v0.2.7. Keep the actual
  // registry, including its non-standard methods, rather than guessing aliases.
  static const shadowsocksCiphers = {
    'none',
    'aes-128-gcm',
    'aes-192-gcm',
    'aes-256-gcm',
    'chacha20-ietf-poly1305',
    'xchacha20-ietf-poly1305',
    'chacha8-ietf-poly1305',
    'xchacha8-ietf-poly1305',
    'rabbit128-poly1305',
    'aes-128-ccm',
    'aes-192-ccm',
    'aes-256-ccm',
    'aes-128-gcm-siv',
    'aes-256-gcm-siv',
    'aegis-128l',
    'aegis-256',
    'aez-384',
    'deoxys-ii-256-128',
    'lea-128-gcm',
    'lea-192-gcm',
    'lea-256-gcm',
    'ascon128',
    'ascon128a',
    'aes-128-ctr',
    'aes-192-ctr',
    'aes-256-ctr',
    'aes-128-cfb',
    'aes-192-cfb',
    'aes-256-cfb',
    'rc4-md5',
    'chacha20-ietf',
    'xchacha20',
    'chacha20',
    '2022-blake3-aes-128-gcm',
    '2022-blake3-aes-256-gcm',
    '2022-blake3-chacha20-poly1305',
    '2022-blake3-chacha8-poly1305',
    '2022-blake3-aes-128-ccm',
    '2022-blake3-aes-256-ccm',
  };

  static const shadowsocksPlugins = {
    'obfs',
    'v2ray-plugin',
    'gost-plugin',
    'shadow-tls',
    'restls',
    'kcptun',
  };

  static const _stringOptions = {
    'host',
    'path',
    'fingerprint',
    'certificate',
    'private-key',
    'password',
    'key',
    'crypt',
    'version-hint',
    'restls-script',
    'mode',
  };
  static const _booleanOptions = {
    'tls',
    'mux',
    'skip-cert-verify',
    'v2ray-http-upgrade',
    'v2ray-http-upgrade-fast-open',
    'nocomp',
    'acknodelay',
  };
  static const _integerOptions = {
    'version',
    'conn',
    'autoexpire',
    'scavengettl',
    'mtu',
    'ratelimit',
    'sndwnd',
    'rcvwnd',
    'datashard',
    'parityshard',
    'dscp',
    'nodelay',
    'interval',
    'resend',
    'nc',
    'sockbuf',
    'smuxver',
    'smuxbuf',
    'framesize',
    'streambuf',
    'keepalive',
  };

  static bool shadowsocks(Map<Object?, Object?> proxy) {
    final cipher = proxy['cipher'];
    if (cipher is! String || !shadowsocksCiphers.contains(cipher)) return false;
    if (cipher.startsWith('2022-') &&
        !_valid2022Keys(cipher, proxy['password'])) {
      return false;
    }
    final plugin = proxy['plugin'];
    if (plugin == null || plugin == '') return true;
    if (!shadowsocksPlugins.contains(plugin)) return false;
    final raw = proxy['plugin-opts'];
    if (raw != null && raw is! Map) return false;
    final options = raw as Map? ?? const {};
    if (plugin == 'obfs' && !const {'http', 'tls'}.contains(options['mode'])) {
      return false;
    }
    if ((plugin == 'v2ray-plugin' || plugin == 'gost-plugin') &&
        options['mode'] != 'websocket') {
      return false;
    }
    if ((plugin == 'shadow-tls' || plugin == 'restls') &&
        options['host'] is! String) {
      return false;
    }
    if (plugin == 'restls' &&
        (options['password'] is! String ||
            !const {'tls12', 'tls13'}.contains(options['version-hint']))) {
      return false;
    }
    for (final key in _stringOptions) {
      if (options[key] != null && options[key] is! String) return false;
    }
    for (final key in _booleanOptions) {
      final value = options[key];
      if (value != null && value is! bool) return false;
    }
    for (final key in _integerOptions) {
      final value = options[key];
      if (value == null) continue;
      final number = value is int
          ? value
          : value is String
              ? int.tryParse(value)
              : null;
      if (number == null || number < 0 || number > 0x7fffffff) return false;
    }
    final alpn = options['alpn'];
    if (alpn != null && (alpn is! List || alpn.any((v) => v is! String))) {
      return false;
    }
    final headers = options['headers'];
    if (headers != null &&
        (headers is! Map ||
            headers.entries
                .any((e) => e.key is! String || e.value is! String))) {
      return false;
    }
    final ech = options['ech-opts'];
    return ech == null || ech is Map;
  }

  static bool _valid2022Keys(String cipher, Object? password) {
    if (password is! String) return false;
    final keys = password.split(':');
    if (cipher.contains('chacha') && keys.length != 1) return false;
    final expectedLength = cipher.contains('aes-128') ? 16 : 32;
    for (final key in keys) {
      // Go StdEncoding accepts CR/LF, but not URL-safe or unpadded base64.
      final encoded = key.replaceAll(RegExp(r'[\r\n]'), '');
      if (encoded.length % 4 != 0 ||
          !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(encoded)) {
        return false;
      }
      try {
        if (base64Decode(encoded).length != expectedLength) return false;
      } on FormatException {
        return false;
      }
    }
    return true;
  }

  static bool hysteria2(Map<Object?, Object?> proxy) =>
      _optionalRange(proxy['ports'], minimum: 1, maximum: 65535) &&
      _optionalRange(proxy['hop-interval'],
          minimum: 0, maximum: 9223372036, allowList: false);

  static bool _optionalRange(Object? value,
      {required int minimum, required int maximum, bool allowList = true}) {
    if (value == null || value == '') return true;
    if (value is! String && value is! int) return false;
    return validUnsignedRanges('$value',
        minimum: minimum, maximum: maximum, allowList: allowList);
  }

  // Go time.Duration stores nanoseconds in a signed 64-bit integer; callers
  // validating hop intervals use a seconds ceiling that cannot overflow it.
  static bool validUnsignedRanges(String value,
      {required int minimum, required int maximum, bool allowList = true}) {
    if (!RegExp(r'^\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*$').hasMatch(value) ||
        (!allowList && value.contains(','))) {
      return false;
    }
    for (final item in value.split(',')) {
      final range = item.split('-').map(int.tryParse).toList();
      if (range.any((n) => n == null || n < minimum || n > maximum) ||
          range.first! > range.last!) {
        return false;
      }
    }
    return true;
  }
}
