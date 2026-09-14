import 'dart:io';

class ForceProxySitePolicy {
  static const int defaultLimit = 5;

  static String? canonicalHostKey(String site) {
    final host = extractHost(site);
    if (host == null) return null;
    final address = InternetAddress.tryParse(host);
    return address == null ? host : 'ip:${address.rawAddress.join('.')}';
  }

  static List<String> normalize(
    Iterable<Object?>? sites, {
    int limit = defaultLimit,
  }) {
    final values =
        sites?.map((site) => site?.toString().trim() ?? '').toList() ??
            const <String>[];
    return List<String>.generate(
      limit,
      (index) => index < values.length ? values[index] : '',
      growable: false,
    );
  }

  static String? extractHost(String site) {
    var value = site.trim();
    if (value.isEmpty || RegExp(r'[\s,，;；]').hasMatch(value)) return null;
    if (value.startsWith('*.')) value = value.substring(2);

    final literal = InternetAddress.tryParse(value);
    if (literal != null) {
      return value.contains('%') ? null : literal.address.toLowerCase();
    }

    if (value.startsWith('[') &&
        !RegExp(r'^\[[^\]]+\](?::\d+)?$').hasMatch(value)) {
      return null;
    }

    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(value);
    final source = hasScheme ? value : 'https://$value';
    // Encoded paths/queries are normal; encoded authorities and IPv6 zones
    // must not be silently decoded into a different routing target.
    final authorityStart = source.indexOf('://') + 3;
    final authority =
        source.substring(authorityStart).split(RegExp(r'[/\?#]')).first;
    if (authority.contains('%')) return null;
    final uri = Uri.tryParse(source);
    var host = uri?.host.trim().toLowerCase();
    if (host == null || host.isEmpty) return null;
    if (host.startsWith('*.')) host = host.substring(2);
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    if (host.isEmpty || host.contains('..') || !isValidHost(host)) {
      return null;
    }
    return host;
  }

  static bool isValidHost(String host) {
    final address = InternetAddress.tryParse(host);
    if (address != null) return true;
    if (host.contains(':')) return false;
    if (RegExp(r'^\d+(?:\.\d+){3}$').hasMatch(host)) return false;

    if (host.length > 253) return false;
    final labels = host.split('.');
    if (labels.length < 2) return false;
    final labelPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
    return labels.every(labelPattern.hasMatch);
  }
}
