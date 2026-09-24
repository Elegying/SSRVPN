import 'dart:convert';
import 'proxy_option_types.dart';

/// Transport fields shared by URI import, YAML import and local node editing.
/// Invalid entries must be filtered before a single bad proxy can prevent the
/// core from loading the complete subscription. Unknown optional keys are kept.
class ProxyTransportValidation {
  static bool protocolOptions(String type, Map<Object?, Object?> proxy) {
    if (!_validTlsOptions(proxy)) return false;
    switch (type) {
      case 'vmess':
        return const {'auto', 'none', 'aes-128-gcm', 'chacha20-poly1305'}
            .contains(proxy['cipher'] ?? 'auto');
      case 'vless':
        return _validVlessEncryption(proxy['encryption']?.toString() ?? '');
      case 'ssr':
        final cipher = proxy['cipher']?.toString() ?? '';
        return (cipher == 'none' ||
                cipher == 'dummy' ||
                const {
                  'rc4-md5',
                  'aes-128-ctr',
                  'aes-192-ctr',
                  'aes-256-ctr',
                  'aes-128-cfb',
                  'aes-192-cfb',
                  'aes-256-cfb',
                  'chacha20',
                  'chacha20-ietf',
                  'xchacha20'
                }.contains(cipher.toLowerCase())) &&
            const {
              'origin',
              'auth_sha1_v4',
              'auth_aes128_md5',
              'auth_aes128_sha1',
              'auth_chain_a',
              'auth_chain_b'
            }.contains(proxy['protocol']) &&
            const {
              'plain',
              'http_simple',
              'http_post',
              'random_head',
              'tls1.2_ticket_auth',
              'tls1.2_ticket_fastauth'
            }.contains(proxy['obfs']);
      case 'snell':
        final version = ProxyOptionTypes.integerValue(proxy['version']) ?? 0;
        final udp =
            proxy['udp'] == true || (proxy['udp'] is int && proxy['udp'] != 0);
        if (version < 0 ||
            version > 5 ||
            (udp && (version == 1 || version == 2))) {
          return false;
        }
        final options = proxy['obfs-opts'];
        return options == null ||
            (options is Map &&
                const {null, '', 'http', 'tls'}.contains(options['mode']) &&
                (options['host'] == null ||
                    options['host'] is String ||
                    options['host'] is num));
      case 'hysteria':
        final auth = proxy['auth']?.toString() ?? '';
        return (auth.isEmpty || _base64Bytes(auth) != null) &&
            _validBandwidth(proxy['up']) &&
            _validBandwidth(proxy['down']);
      case 'trojan':
        final ss = proxy['ss-opts'];
        if (ss is Map &&
            (ss['enabled'] == true ||
                (ss['enabled'] is int && ss['enabled'] != 0))) {
          final method = ss['method']?.toString().toLowerCase() ?? '';
          return (ss['password']?.toString().isNotEmpty ?? false) &&
              (method.isEmpty || _trojanShadowsocksCiphers.contains(method));
        }
        return true;
      case 'hysteria2':
        final obfs = proxy['obfs'];
        return obfs == null ||
            obfs == '' ||
            (const {'salamander', 'gecko'}.contains(obfs) &&
                (proxy['obfs-password']?.toString().isNotEmpty ?? false));
    }
    return true;
  }

  // Trojan-Go uses transport/shadowsocks/core, not sing-shadowsocks2.
  static const _trojanShadowsocksCiphers = {
    'dummy',
    'rc4-md5',
    'aes-128-ctr',
    'aes-192-ctr',
    'aes-256-ctr',
    'aes-128-cfb',
    'aes-192-cfb',
    'aes-256-cfb',
    'chacha20',
    'chacha20-ietf',
    'xchacha20',
    'aes-128-gcm',
    'aes-192-gcm',
    'aes-256-gcm',
    'chacha20-ietf-poly1305',
    'xchacha20-ietf-poly1305',
    'chacha8-ietf-poly1305',
    'xchacha8-ietf-poly1305',
    'aes-128-ccm',
    'aes-192-ccm',
    'aes-256-ccm',
    'aead_aes_128_gcm',
    'aead_aes_192_gcm',
    'aead_aes_256_gcm',
    'aead_chacha20_poly1305',
    'aead_xchacha20_poly1305',
    'aead_chacha8_poly1305',
    'aead_xchacha8_poly1305',
    'aead_aes_128_ccm',
    'aead_aes_192_ccm',
    'aead_aes_256_ccm',
  };

  static bool _validTlsOptions(Map<Object?, Object?> proxy) {
    final reality = proxy['reality-opts'];
    if (reality is Map) {
      final key = reality['public-key']?.toString() ?? '';
      if (key.isNotEmpty) {
        if (_base64Bytes(key, rawUrl: true)?.length != 32) return false;
        final shortId = reality['short-id']?.toString() ?? '';
        if (shortId.length > 16 ||
            shortId.length.isOdd ||
            !RegExp(r'^[a-fA-F0-9]*$').hasMatch(shortId)) {
          return false;
        }
      }
    }
    final ech = proxy['ech-opts'];
    if (ech is Map &&
        (ech['enable'] == true ||
            (ech['enable'] is int && ech['enable'] != 0))) {
      final config = ech['config']?.toString() ?? '';
      if (config.isNotEmpty && _base64Bytes(config) == null) return false;
    }
    return true;
  }

  static List<int>? _base64Bytes(String value, {bool rawUrl = false}) {
    final encoded = value.replaceAll(RegExp(r'[\r\n]'), '');
    if (rawUrl
        ? !RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(encoded)
        : encoded.length % 4 != 0 ||
            !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(encoded)) {
      return null;
    }
    try {
      return base64Decode(base64.normalize(encoded));
    } on FormatException {
      return null;
    }
  }

  static bool _validBandwidth(Object? value) {
    if (value == null) return false;
    var text = '$value';
    if (RegExp(r'^\+?\d+$').hasMatch(text)) {
      text = '${int.tryParse(text) ?? 0} Mbps';
    }
    final match = RegExp(r'^(\d+)\s*([KMGT]?)([Bb])ps$').firstMatch(text);
    if (match == null) return false;
    final digits = match[1]!.replaceFirst(RegExp(r'^0+'), '');
    final maximum = (BigInt.one << 64) - BigInt.one;
    var number = digits.length > 20
        ? maximum
        : BigInt.parse(digits.isEmpty ? '0' : digits);
    // The pinned core uses the saturated ParseUint value on range overflow.
    if (number > maximum) number = maximum;
    final power = const {'': 0, 'K': 1, 'M': 2, 'G': 3, 'T': 4}[match[2]]!;
    number = (number * BigInt.from(1000).pow(power)).toUnsigned(64);
    if (match[3] == 'b') number ~/= BigInt.from(8);
    return number > BigInt.zero;
  }

  static bool _validVlessEncryption(String value) {
    if (value.isEmpty || value == 'none') return true;
    final parts = value.split('.');
    if (parts.length < 4 ||
        parts[0] != 'mlkem768x25519plus' ||
        !const {'native', 'xorpub', 'random'}.contains(parts[1]) ||
        !const {'0rtt', '1rtt'}.contains(parts[2])) {
      return false;
    }
    var keys = 0;
    final padding = <String>[];
    for (final part in parts.skip(3)) {
      if (part.length < 20) {
        padding.add(part);
        continue;
      }
      final key = _base64Bytes(part, rawUrl: true);
      if (key == null || (key.length != 32 && key.length != 1184)) return false;
      // ML-KEM public coefficients must be canonically encoded modulo 3329.
      if (key.length == 1184) {
        for (var i = 0; i < 1152; i += 3) {
          if ((key[i] | ((key[i + 1] & 15) << 8)) >= 3329 ||
              ((key[i + 1] >> 4) | (key[i + 2] << 4)) >= 3329) {
            return false;
          }
        }
      }
      keys++;
    }
    if (keys == 0) return false;
    if (padding.join('.').isEmpty) return true;
    var total = 0;
    for (var i = 0; i < padding.length; i++) {
      final lengths = padding[i].split('-');
      if (lengths.length < 3) return false;
      final values = lengths.take(3).map(int.tryParse).toList();
      if (values.any((n) => n == null)) return false;
      if (i == 0 && (values[0]! < 100 || values[1]! < 35 || values[2]! < 35)) {
        return false;
      }
      if (i.isEven) total += values[1]! > values[2]! ? values[1]! : values[2]!;
    }
    return total <= 65553;
  }

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
