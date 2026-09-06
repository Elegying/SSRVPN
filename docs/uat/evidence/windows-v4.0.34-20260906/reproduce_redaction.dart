// Run from the repository root using its package configuration.
// This fixture contains no real username, endpoint, password or subscription.
import 'dart:convert';
import 'package:ssrvpn_shared/utils/log_redactor.dart';

void main() {
  const normal =
      r'Load MMDB file: C:\Users\UAT_FIXTURE_USER\AppData\Local\Programs\SSRVPN\bin\ssrvpn/geoip.metadb';
  const escaped =
      r'Load MMDB file: C:\\Users\\UAT_FIXTURE_USER\\AppData\\Local\\Programs\\SSRVPN\\bin\\ssrvpn/geoip.metadb';
  print(jsonEncode({
    'normal_username_leaks':
        LogRedactor.sanitizeForDisplay(normal).contains('UAT_FIXTURE_USER'),
    'escaped_username_leaks':
        LogRedactor.sanitizeForDisplay(escaped).contains('UAT_FIXTURE_USER'),
  }));
}
