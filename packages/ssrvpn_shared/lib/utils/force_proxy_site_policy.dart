import 'dart:io';

class ForceProxySitePolicy {
  static const int defaultLimit = 5;

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
    if (value.contains('%')) return null;
    if (value.startsWith('*.')) value = value.substring(2);

    final literal = InternetAddress.tryParse(value);
    if (literal != null) return literal.address.toLowerCase();

    if (value.startsWith('[') &&
        !RegExp(r'^\[[^\]]+\](?::\d+)?$').hasMatch(value)) {
      return null;
    }

    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(value);
    final uri = Uri.tryParse(hasScheme ? value : 'https://$value');
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

    final labels = host.split('.');
    if (labels.length < 2) return false;
    final labelPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
    return labels.every(labelPattern.hasMatch);
  }
}
