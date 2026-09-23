part of 'subscription_parser.dart';

/// SIP002 and the legacy whole-payload Base64 form use different escaping.
/// Decode the legacy payload before URI parsing can lowercase its authority.
class _ShadowsocksUriParser {
  static Map<String, dynamic>? parse(String line) {
    try {
      var uri = Uri.tryParse(line);
      String? cipher;
      String? password;
      if (!line.substring(5).split('#').first.contains('@')) {
        final fragment = line.indexOf('#');
        final encoded = line.substring(5, fragment < 0 ? null : fragment);
        final decoded =
            _SubscriptionBase64.decodeText(encoded, fieldName: 'SS链接');
        final at = decoded.lastIndexOf('@');
        final colon = decoded.indexOf(':');
        if (colon <= 0 || at <= colon + 1) return null;
        cipher = decoded.substring(0, colon);
        password = decoded.substring(colon + 1, at);
        uri = Uri.tryParse('ss://legacy@${decoded.substring(at + 1)}'
            '${fragment < 0 ? '' : line.substring(fragment)}');
      }
      if (uri == null ||
          !uri.hasPort ||
          uri.port < 1 ||
          uri.port > 65535 ||
          !ProxyNodeUsagePolicy.isValidServerValue(uri.host)) {
        return null;
      }
      if (cipher == null) {
        final credentials =
            _SubscriptionUriParser._parseSsCredentials(uri.userInfo);
        if (credentials == null) return null;
        cipher = credentials.cipher;
        password = credentials.password;
      }
      final proxy = <String, dynamic>{
        'name': _SubscriptionUriParser._proxyNameFromUri(uri),
        'type': 'ss',
        'server': uri.host,
        'port': uri.port,
        'cipher': cipher,
        'password': password,
        'udp': true,
      };
      final plugin = uri.queryParameters['plugin'];
      if (plugin != null && plugin.isNotEmpty && !_applyPlugin(proxy, plugin)) {
        return null;
      }
      return proxy;
    } on FormatException {
      return null;
    }
  }

  static bool _applyPlugin(Map<String, dynamic> proxy, String text) {
    final fields = <String, dynamic>{};
    var token = StringBuffer();
    String? key;
    var escaped = false;
    void finish() {
      final name = (key ?? token.toString()).trim();
      if (name.isEmpty || fields.containsKey(name)) {
        throw const FormatException('Invalid SS plugin option');
      }
      fields[name] = key == null ? true : token.toString();
      key = null;
      token = StringBuffer();
    }

    for (final rune in text.runes) {
      if (escaped) {
        token.writeCharCode(rune);
        escaped = false;
      } else if (rune == 92) {
        escaped = true;
      } else if (rune == 59) {
        finish();
      } else if (rune == 61 && key == null) {
        key = token.toString();
        token = StringBuffer();
      } else {
        token.writeCharCode(rune);
      }
    }
    if (escaped) return false;
    finish();
    var plugin = fields.keys.first;
    if (fields.remove(plugin) != true) return false;
    if (plugin == 'obfs-local' || plugin == 'simple-obfs') plugin = 'obfs';
    if (!ProxyNodeUsagePolicy.supportedShadowsocksPlugins.contains(plugin)) {
      return false;
    }
    if (plugin == 'obfs') {
      if (fields.containsKey('obfs')) fields['mode'] = fields.remove('obfs');
      if (fields.containsKey('obfs-host')) {
        fields['host'] = fields.remove('obfs-host');
      }
      if (!const {'http', 'tls'}.contains(fields['mode'])) return false;
    }
    if (plugin == 'v2ray-plugin' || plugin == 'gost-plugin') {
      fields.putIfAbsent('mode', () => 'websocket');
      if (fields['mode'] != 'websocket') return false;
    }
    // SIP002 bare tokens are flags, not string/numeric values. Letting one
    // reach Mihomo in a typed field rejects the entire generated config.
    for (final option in [
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
      'alpn',
    ]) {
      if (fields.containsKey(option) && fields[option] is! String) return false;
    }
    // These structured YAML fields have no scalar SIP002 representation.
    if (fields.containsKey('headers') || fields.containsKey('ech-opts')) {
      return false;
    }
    for (final option in [
      'tls',
      'mux',
      'skip-cert-verify',
      'v2ray-http-upgrade',
      'v2ray-http-upgrade-fast-open',
      'nocomp',
      'acknodelay',
    ]) {
      final value = fields[option];
      if (value is String) {
        if (!const {'true', 'false', '1', '0'}.contains(value)) return false;
        fields[option] = value == 'true' || value == '1';
      }
    }
    for (final option in [
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
    ]) {
      if (!fields.containsKey(option)) continue;
      final value = fields[option];
      final parsed = value is String ? int.tryParse(value) : null;
      if (parsed == null || parsed < 0 || parsed > 0x7fffffff) return false;
      fields[option] = parsed;
    }
    if (fields['alpn'] is String) {
      fields['alpn'] = (fields['alpn'] as String).split(',');
    }
    proxy['plugin'] = plugin;
    if (fields.isNotEmpty) proxy['plugin-opts'] = fields;
    return true;
  }
}
