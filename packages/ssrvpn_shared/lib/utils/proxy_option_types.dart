/// Shapes consumed by the pinned cores' `common/structure` decoder.
/// Unknown options are retained. Numeric text/credentials and integer booleans
/// remain compatible with the core's weak decoding; arbitrary lists/maps do not.
class ProxyOptionTypes {
  /// Resolve the core's case/underscore aliases once, before validation and
  /// emission. Exact keys win, as in the core decoder. This also makes multiple
  /// aliases deterministic instead of depending on Go map iteration order.
  static Map<Object?, Object?> canonicalize(Map<Object?, Object?> options) {
    final type = options['type']?.toString().trim().toLowerCase();
    final result = _canonicalMap(options, 'BasicOption');
    result.addAll(_canonicalMap(result, _protocols[type] ?? 'unknown'));
    result['type'] = type == 'socks' ? 'socks5' : type;
    // UI, latency probes and edits interpret ports as decimal integers. Emit
    // that same endpoint, avoiding the core's octal decoding of quoted ports.
    if (result['port'] case final String port) {
      result['port'] = int.tryParse(port) ?? port;
    }
    if (result['server'] case final String server) {
      result['server'] = server.trim();
    }
    if (type == 'vmess') {
      result['cipher'] ??= 'auto';
      result['alterId'] ??= options['alter-id'] ?? 0;
    }
    return result;
  }

  static Map<Object?, Object?> _canonicalMap(
      Map<Object?, Object?> options, String type) {
    final result = Map<Object?, Object?>.from(options);
    for (final field in (_coreOptionFields[type] ?? const {}).entries) {
      final aliases = options.keys.where((key) =>
          key is String &&
          key.replaceAll('_', '-').toLowerCase() == field.key.toLowerCase());
      if (aliases.isEmpty) continue;
      final key = options.containsKey(field.key) ? field.key : aliases.first;
      final value = options[key];
      result[field.key] =
          value is Map && _coreOptionFields.containsKey(field.value)
              ? _canonicalMap(Map<Object?, Object?>.from(value), field.value)
              : value;
    }
    return result;
  }

  static const _protocols = {
    'ss': 'ShadowSocksOption',
    'ssr': 'ShadowSocksROption',
    'vmess': 'VmessOption',
    'vless': 'VlessOption',
    'trojan': 'TrojanOption',
    'anytls': 'AnyTLSOption',
    'hysteria': 'HysteriaOption',
    'hysteria2': 'Hysteria2Option',
    'tuic': 'TuicOption',
    'snell': 'SnellOption',
    'socks': 'Socks5Option',
    'socks5': 'Socks5Option',
    'http': 'HttpOption',
  };

  static bool accepts(String protocol, Map<Object?, Object?> options) =>
      _matches(options, 'BasicOption') &&
      _matches(options, _protocols[protocol] ?? 'unknown');

  static bool _matches(Object? value, String type) {
    if (value == null) return true;
    switch (type) {
      case 'string':
      case 'C.DNSPrefer':
        return value is String || (value is num && value.isFinite);
      case 'bool':
        return value is bool || value is int;
      case 'int':
      case 'uint64':
        return value is num
            ? value.isFinite
            : value is String &&
                _parseInteger(value, unsigned: type == 'uint64') != null;
      case '[]string':
        return value is List && value.every((v) => _matches(v, 'string'));
      case 'map[string]string':
      case 'map[string][]string':
        final child = type == 'map[string]string' ? 'string' : '[]string';
        return value is Map &&
            value.entries.every((entry) =>
                _matches(entry.key, 'string') && _matches(entry.value, child));
      case 'map[string]any':
        return value is Map;
    }
    final fields = _coreOptionFields[type];
    if (fields == null) return true;
    if (value is! Map) return false;
    return value.entries.every((entry) {
      final fieldType = fields[entry.key];
      return fieldType == null || _matches(entry.value, fieldType);
    });
  }

  // Match strconv.ParseInt/ParseUint with base 0, including prefixed literals
  // and separators; do not accept decimal "08" which the core treats as octal.
  static int? integerValue(Object? value) => value is num
      ? (value.isFinite ? value.toInt() : null)
      : value is String
          ? _parseInteger(value, unsigned: false)?.toInt()
          : null;

  static BigInt? _parseInteger(String text, {required bool unsigned}) {
    var digits = text;
    var negative = false;
    if (digits.startsWith('-') || digits.startsWith('+')) {
      if (unsigned) return null;
      negative = digits.startsWith('-');
      digits = digits.substring(1);
    }
    var radix = 10;
    if (digits.length > 1 && digits.startsWith('0')) {
      radix = switch (digits[1].toLowerCase()) {
        'x' => 16,
        'b' => 2,
        'o' => 8,
        _ => 8,
      };
      digits = digits.substring(
          const ['x', 'b', 'o'].contains(digits[1].toLowerCase()) ? 2 : 1);
      if (digits.startsWith('_')) digits = digits.substring(1);
    }
    final alphabet = switch (radix) {
      2 => '[01]',
      8 => '[0-7]',
      16 => '[0-9a-fA-F]',
      _ => '[0-9]',
    };
    if (!RegExp('^$alphabet(?:_?$alphabet)*\$').hasMatch(digits)) return null;
    final significant =
        digits.replaceAll('_', '').replaceFirst(RegExp(r'^0+'), '');
    final maxDigits = switch (radix) { 2 => 64, 8 => 22, 16 => 16, _ => 20 };
    if (significant.length > maxDigits) return null;
    final number =
        BigInt.tryParse(significant.isEmpty ? '0' : significant, radix: radix);
    if (number == null) return null;
    final limit = BigInt.one << (unsigned ? 64 : 63);
    if (negative ? number > limit : number >= limit) return null;
    return negative ? -number : number;
  }
}

// Common option layouts: Windows 5184081a, Android 7031b756. macOS
// e26714a1 retains these fields with the same types. Update with core pins.
const _coreOptionFields = <String, Map<String, String>>{
  'AnyTLSOption': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'password': 'string',
    'alpn': '[]string',
    'sni': 'string',
    'ech-opts': 'ECHOptions',
    'client-fingerprint': 'string',
    'skip-cert-verify': 'bool',
    'fingerprint': 'string',
    'certificate': 'string',
    'private-key': 'string',
    'udp': 'bool',
    'idle-session-check-interval': 'int',
    'idle-session-timeout': 'int',
    'min-idle-session': 'int',
  },
  'BasicOption': {
    'tfo': 'bool',
    'mptcp': 'bool',
    'interface-name': 'string',
    'routing-mark': 'int',
    'ip-version': 'C.DNSPrefer',
    'dialer-proxy': 'string',
  },
  'ECHOptions': {
    'enable': 'bool',
    'config': 'string',
    'query-server-name': 'string',
  },
  'GrpcOptions': {
    'grpc-service-name': 'string',
    'grpc-user-agent': 'string',
    'ping-interval': 'int',
    'max-connections': 'int',
    'min-streams': 'int',
    'max-streams': 'int',
  },
  'HTTP2Options': {
    'host': '[]string',
    'path': 'string',
  },
  'HTTPOptions': {
    'method': 'string',
    'path': '[]string',
    'headers': 'map[string][]string',
  },
  'HttpOption': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'username': 'string',
    'password': 'string',
    'tls': 'bool',
    'sni': 'string',
    'skip-cert-verify': 'bool',
    'fingerprint': 'string',
    'certificate': 'string',
    'private-key': 'string',
    'headers': 'map[string]string',
  },
  'Hysteria2Option': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'ports': 'string',
    'hop-interval': 'string',
    'up': 'string',
    'down': 'string',
    'password': 'string',
    'obfs': 'string',
    'obfs-password': 'string',
    'obfs-min-packet-size': 'int',
    'obfs-max-packet-size': 'int',
    'sni': 'string',
    'ech-opts': 'ECHOptions',
    'skip-cert-verify': 'bool',
    'fingerprint': 'string',
    'certificate': 'string',
    'private-key': 'string',
    'alpn': '[]string',
    'cwnd': 'int',
    'bbr-profile': 'string',
    'udp-mtu': 'int',
    'realm-opts': 'Hysteria2RealmOption',
    'initial-stream-receive-window': 'uint64',
    'max-stream-receive-window': 'uint64',
    'initial-connection-receive-window': 'uint64',
    'max-connection-receive-window': 'uint64',
  },
  'Hysteria2RealmOption': {
    'enable': 'bool',
    'server-url': 'string',
    'token': 'string',
    'realm-id': 'string',
    'stun-servers': '[]string',
    'sni': 'string',
    'skip-cert-verify': 'bool',
    'fingerprint': 'string',
    'certificate': 'string',
    'private-key': 'string',
    'alpn': '[]string',
  },
  'HysteriaOption': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'ports': 'string',
    'protocol': 'string',
    'obfs-protocol': 'string',
    'up': 'string',
    'up-speed': 'int',
    'down': 'string',
    'down-speed': 'int',
    'auth': 'string',
    'auth-str': 'string',
    'obfs': 'string',
    'sni': 'string',
    'ech-opts': 'ECHOptions',
    'skip-cert-verify': 'bool',
    'fingerprint': 'string',
    'certificate': 'string',
    'private-key': 'string',
    'alpn': '[]string',
    'recv-window-conn': 'int',
    'recv-window': 'int',
    'disable-mtu-discovery': 'bool',
    'fast-open': 'bool',
    'hop-interval': 'int',
  },
  'RealityOptions': {
    'public-key': 'string',
    'short-id': 'string',
    'support-x25519mlkem768': 'bool',
  },
  'ShadowSocksOption': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'password': 'string',
    'cipher': 'string',
    'udp': 'bool',
    'plugin': 'string',
    'plugin-opts': 'map[string]any',
    'udp-over-tcp': 'bool',
    'udp-over-tcp-version': 'int',
    'client-fingerprint': 'string',
  },
  'ShadowSocksROption': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'password': 'string',
    'cipher': 'string',
    'obfs': 'string',
    'obfs-param': 'string',
    'protocol': 'string',
    'protocol-param': 'string',
    'udp': 'bool',
  },
  'SnellOption': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'psk': 'string',
    'udp': 'bool',
    'version': 'int',
    'reuse': 'bool',
    'obfs-opts': 'map[string]any',
  },
  'Socks5Option': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'username': 'string',
    'password': 'string',
    'tls': 'bool',
    'udp': 'bool',
    'skip-cert-verify': 'bool',
    'fingerprint': 'string',
    'certificate': 'string',
    'private-key': 'string',
  },
  'TrojanOption': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'password': 'string',
    'alpn': '[]string',
    'sni': 'string',
    'skip-cert-verify': 'bool',
    'fingerprint': 'string',
    'certificate': 'string',
    'private-key': 'string',
    'udp': 'bool',
    'network': 'string',
    'ech-opts': 'ECHOptions',
    'reality-opts': 'RealityOptions',
    'grpc-opts': 'GrpcOptions',
    'ws-opts': 'WSOptions',
    'ss-opts': 'TrojanSSOption',
    'client-fingerprint': 'string',
  },
  'TrojanSSOption': {
    'enabled': 'bool',
    'method': 'string',
    'password': 'string',
  },
  'TuicOption': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'token': 'string',
    'uuid': 'string',
    'password': 'string',
    'ip': 'string',
    'heartbeat-interval': 'int',
    'alpn': '[]string',
    'reduce-rtt': 'bool',
    'request-timeout': 'int',
    'udp-relay-mode': 'string',
    'congestion-controller': 'string',
    'disable-sni': 'bool',
    'max-udp-relay-packet-size': 'int',
    'fast-open': 'bool',
    'max-open-streams': 'int',
    'cwnd': 'int',
    'bbr-profile': 'string',
    'skip-cert-verify': 'bool',
    'fingerprint': 'string',
    'certificate': 'string',
    'private-key': 'string',
    'recv-window-conn': 'int',
    'recv-window': 'int',
    'disable-mtu-discovery': 'bool',
    'max-datagram-frame-size': 'int',
    'sni': 'string',
    'ech-opts': 'ECHOptions',
    'udp-over-stream': 'bool',
    'udp-over-stream-version': 'int',
  },
  'VlessOption': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'uuid': 'string',
    'flow': 'string',
    'tls': 'bool',
    'alpn': '[]string',
    'udp': 'bool',
    'packet-addr': 'bool',
    'xudp': 'bool',
    'packet-encoding': 'string',
    'encryption': 'string',
    'network': 'string',
    'ech-opts': 'ECHOptions',
    'reality-opts': 'RealityOptions',
    'http-opts': 'HTTPOptions',
    'h2-opts': 'HTTP2Options',
    'grpc-opts': 'GrpcOptions',
    'ws-opts': 'WSOptions',
    'xhttp-opts': 'XHTTPOptions',
    'ws-headers': 'map[string]string',
    'skip-cert-verify': 'bool',
    'fingerprint': 'string',
    'certificate': 'string',
    'private-key': 'string',
    'servername': 'string',
    'client-fingerprint': 'string',
  },
  'VmessOption': {
    'name': 'string',
    'server': 'string',
    'port': 'int',
    'uuid': 'string',
    'alterId': 'int',
    'cipher': 'string',
    'udp': 'bool',
    'network': 'string',
    'tls': 'bool',
    'alpn': '[]string',
    'skip-cert-verify': 'bool',
    'fingerprint': 'string',
    'certificate': 'string',
    'private-key': 'string',
    'servername': 'string',
    'ech-opts': 'ECHOptions',
    'reality-opts': 'RealityOptions',
    'http-opts': 'HTTPOptions',
    'h2-opts': 'HTTP2Options',
    'grpc-opts': 'GrpcOptions',
    'ws-opts': 'WSOptions',
    'packet-addr': 'bool',
    'xudp': 'bool',
    'packet-encoding': 'string',
    'global-padding': 'bool',
    'authenticated-length': 'bool',
    'client-fingerprint': 'string',
  },
  'WSOptions': {
    'path': 'string',
    'headers': 'map[string]string',
    'max-early-data': 'int',
    'early-data-header-name': 'string',
    'v2ray-http-upgrade': 'bool',
    'v2ray-http-upgrade-fast-open': 'bool',
  },
  'XHTTPDownloadSettings': {
    'path': 'string',
    'host': 'string',
    'headers': 'map[string]string',
    'reuse-settings': 'XHTTPReuseSettings',
    'server': 'string',
    'port': 'int',
    'tls': 'bool',
    'alpn': '[]string',
    'ech-opts': 'ECHOptions',
    'reality-opts': 'RealityOptions',
    'skip-cert-verify': 'bool',
    'fingerprint': 'string',
    'certificate': 'string',
    'private-key': 'string',
    'servername': 'string',
    'client-fingerprint': 'string',
  },
  'XHTTPOptions': {
    'path': 'string',
    'host': 'string',
    'mode': 'string',
    'headers': 'map[string]string',
    'no-grpc-header': 'bool',
    'x-padding-bytes': 'string',
    'x-padding-obfs-mode': 'bool',
    'x-padding-key': 'string',
    'x-padding-header': 'string',
    'x-padding-placement': 'string',
    'x-padding-method': 'string',
    'uplink-http-method': 'string',
    'session-placement': 'string',
    'session-key': 'string',
    'seq-placement': 'string',
    'seq-key': 'string',
    'uplink-data-placement': 'string',
    'uplink-data-key': 'string',
    'uplink-chunk-size': 'string',
    'sc-max-each-post-bytes': 'string',
    'sc-min-posts-interval-ms': 'string',
    'reuse-settings': 'XHTTPReuseSettings',
    'download-settings': 'XHTTPDownloadSettings',
  },
  'XHTTPReuseSettings': {
    'max-concurrency': 'string',
    'max-connections': 'string',
    'c-max-reuse-times': 'string',
    'h-max-request-times': 'string',
    'h-max-reusable-secs': 'string',
    'h-keep-alive-period': 'int',
  },
};
