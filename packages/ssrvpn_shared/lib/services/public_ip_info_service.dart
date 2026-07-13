import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import '../models/public_ip_info.dart';

class PublicIpInfoService {
  PublicIpInfoService({required http.Client client}) : _client = client;

  /// This hostname publishes only IPv4 results. The clients support IPv6 for
  /// traffic and nodes, but the home page intentionally presents a stable IPv4
  /// public address.
  static final Uri ipv4Endpoint =
      Uri.parse('https://api4.ipify.org/?format=json');
  static final Uri fallbackEndpoint = Uri.parse('https://api.ip.sb/geoip');

  static Uri geoEndpointForIp(String ip) =>
      Uri.https('api.ip.sb', '/geoip/$ip');

  final http.Client _client;

  Future<PublicIpInfo> fetch({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final ipv4Info = await _fetchIpv4(timeout);
    if (ipv4Info != null) return ipv4Info;

    final response = await _get(fallbackEndpoint, timeout);
    if (response.statusCode != 200) {
      throw PublicIpInfoException('HTTP ${response.statusCode}');
    }
    final info = parse(response.body);
    if (!_isIpv4(info.ip)) {
      throw const PublicIpInfoException('未获取到公网 IPv4 信息');
    }
    return info;
  }

  Future<PublicIpInfo?> _fetchIpv4(Duration timeout) async {
    try {
      final response = await _get(ipv4Endpoint, timeout);
      if (response.statusCode != 200) return null;
      final ip = _parseIpOnly(response.body);
      if (!_isIpv4(ip)) return null;

      try {
        final geoResponse = await _get(geoEndpointForIp(ip!), timeout);
        if (geoResponse.statusCode == 200) {
          final geo = parse(geoResponse.body);
          if (geo.ip == ip) return geo;
        }
      } catch (_) {
        // The IPv4 address itself is still useful when the optional country
        // lookup is unavailable.
      }
      return PublicIpInfo(ip: ip!, countryCode: '');
    } catch (_) {
      return null;
    }
  }

  Future<http.Response> _get(Uri uri, Duration timeout) => _client.get(
        uri,
        headers: const {
          'Accept': 'application/json,text/plain,text/html',
          'User-Agent': AppConstants.appUserAgent,
        },
      ).timeout(timeout);

  static PublicIpInfo parse(String body) {
    final jsonInfo = _parseJsonObject(body);
    if (jsonInfo != null) return jsonInfo;

    final scriptInfo = _parseJsonScript(body);
    if (scriptInfo != null) return scriptInfo;

    final dataInfo = _parseDataAttributes(body);
    if (dataInfo != null) return dataInfo;

    final textInfo = _parseLooseText(body);
    if (textInfo != null) return textInfo;

    throw const PublicIpInfoException('未识别到公网 IP 信息');
  }

  static PublicIpInfo? _parseJsonObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      return _fromParts(
        decoded['ip']?.toString(),
        decoded['country_code']?.toString() ??
            decoded['countryCode']?.toString() ??
            decoded['country']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  static String? _parseIpOnly(String body) {
    try {
      final decoded = jsonDecode(body);
      final value = decoded is Map ? decoded['ip']?.toString().trim() : null;
      return InternetAddress.tryParse(value ?? '') == null ? null : value;
    } catch (_) {
      final value = body.trim();
      return InternetAddress.tryParse(value) == null ? null : value;
    }
  }

  static bool _isIpv4(String? value) =>
      InternetAddress.tryParse(value ?? '')?.type == InternetAddressType.IPv4;

  static PublicIpInfo? _parseJsonScript(String body) {
    final match = RegExp(
      r'''<script[^>]*id=["']ip-json["'][^>]*>(.*?)</script>''',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(body);
    if (match == null) return null;
    try {
      final decoded = jsonDecode(match.group(1)?.trim() ?? '');
      if (decoded is! Map) return null;
      return _fromParts(
        decoded['ip']?.toString(),
        decoded['ip-country']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  static PublicIpInfo? _parseDataAttributes(String body) {
    final ip = RegExp(
      r'''id=["']ip["'][^>]*data-ip=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(body)?.group(1);
    final country = RegExp(
      r'''id=["']ip-country["'][^>]*data-ip-country=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(body)?.group(1);
    return _fromParts(ip, country);
  }

  static PublicIpInfo? _parseLooseText(String body) {
    final ipv4Match = RegExp(
      r'\b((?:\d{1,3}\.){3}\d{1,3})\s+([A-Za-z]{2})\b',
    ).firstMatch(body);
    final ipv4Info = _fromParts(ipv4Match?.group(1), ipv4Match?.group(2));
    if (ipv4Info != null) return ipv4Info;

    for (final match in RegExp(
      r'([0-9A-Fa-f:]*:[0-9A-Fa-f:]+)\s+([A-Za-z]{2})\b',
    ).allMatches(body)) {
      final info = _fromParts(match.group(1), match.group(2));
      if (info != null) return info;
    }
    return null;
  }

  static PublicIpInfo? _fromParts(String? ip, String? countryCode) {
    final normalizedIp = ip?.trim() ?? '';
    final normalizedCountry = countryCode?.trim().toUpperCase() ?? '';
    if (InternetAddress.tryParse(normalizedIp) == null) return null;
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(normalizedCountry)) return null;
    return PublicIpInfo(ip: normalizedIp, countryCode: normalizedCountry);
  }
}

class PublicIpInfoException implements Exception {
  const PublicIpInfoException(this.message);

  final String message;

  @override
  String toString() => message;
}
