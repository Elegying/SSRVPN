import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import '../models/public_ip_info.dart';

class PublicIpInfoService {
  PublicIpInfoService({required http.Client client}) : _client = client;

  static final Uri endpoint = Uri.parse('https://www.whatismyip.com.tw/');

  final http.Client _client;

  Future<PublicIpInfo> fetch({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final response = await _client.get(
      endpoint,
      headers: const {
        'Accept': 'text/html,application/xhtml+xml,application/xml',
        'User-Agent': AppConstants.appUserAgent,
      },
    ).timeout(timeout);
    if (response.statusCode != 200) {
      throw PublicIpInfoException('HTTP ${response.statusCode}');
    }
    return parse(response.body);
  }

  static PublicIpInfo parse(String body) {
    final jsonInfo = _parseJsonScript(body);
    if (jsonInfo != null) return jsonInfo;

    final dataInfo = _parseDataAttributes(body);
    if (dataInfo != null) return dataInfo;

    final textInfo = _parseLooseText(body);
    if (textInfo != null) return textInfo;

    throw const PublicIpInfoException('未识别到公网 IP 信息');
  }

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
    final match = RegExp(
      r'\b((?:\d{1,3}\.){3}\d{1,3})\s+([A-Za-z]{2})\b',
    ).firstMatch(body);
    return _fromParts(match?.group(1), match?.group(2));
  }

  static PublicIpInfo? _fromParts(String? ip, String? countryCode) {
    final normalizedIp = ip?.trim() ?? '';
    final normalizedCountry = countryCode?.trim().toUpperCase() ?? '';
    if (!_isValidIpv4(normalizedIp)) return null;
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(normalizedCountry)) return null;
    return PublicIpInfo(ip: normalizedIp, countryCode: normalizedCountry);
  }

  static bool _isValidIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      final parsed = int.tryParse(part);
      if (parsed == null || parsed < 0 || parsed > 255) return false;
    }
    return true;
  }
}

class PublicIpInfoException implements Exception {
  const PublicIpInfoException(this.message);

  final String message;

  @override
  String toString() => message;
}
