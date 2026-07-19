import 'dart:convert';

import 'package:characters/characters.dart';

class SubscriptionHeaderNameParser {
  const SubscriptionHeaderNameParser._();

  static const _maxNameCharacters = 128;
  static final _controlCharacters = RegExp(
    r'[\u0000-\u001F\u007F-\u009F]',
    unicode: true,
  );
  static final _bidirectionalControls = RegExp(
    r'[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
    unicode: true,
  );
  static final _whitespace = RegExp(
    r'[\s\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+',
    unicode: true,
  );

  static String? fromHeaders(Map<String, String> headers) {
    final profileTitle = _headerValue(headers, 'profile-title');
    if (profileTitle != null) {
      final parsed = _profileTitle(profileTitle);
      if (parsed != null) return parsed;
    }

    final disposition = _headerValue(headers, 'content-disposition');
    if (disposition == null) return null;
    final filename = RegExp(
      "filename\\*?=(?:UTF-8'')?\"?([^\";]+)\"?",
      caseSensitive: false,
    ).firstMatch(disposition)?.group(1);
    return filename == null ? null : _clean(filename);
  }

  static String? _headerValue(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  static String? _profileTitle(String value) {
    var text = value.trim();
    if (text.length >= 2 &&
        ((text.startsWith('"') && text.endsWith('"')) ||
            (text.startsWith("'") && text.endsWith("'")))) {
      text = text.substring(1, text.length - 1).trim();
    }
    final storeName = RegExp(
      r'(?:^|[;,\s])store-name="?([^";,]+)"?',
      caseSensitive: false,
    ).firstMatch(text);
    return _clean(storeName?.group(1) ?? text);
  }

  static String? _clean(String value) {
    var name = value.trim();
    if (name.length >= 2 &&
        ((name.startsWith('"') && name.endsWith('"')) ||
            (name.startsWith("'") && name.endsWith("'")))) {
      name = name.substring(1, name.length - 1).trim();
    }
    if (name.toLowerCase().startsWith('base64:')) {
      try {
        name = utf8.decode(base64Decode(name.substring(7))).trim();
      } catch (_) {}
    }
    try {
      name = Uri.decodeComponent(name).trim();
    } catch (_) {}
    name = name
        .replaceAll(_controlCharacters, ' ')
        .replaceAll(_bidirectionalControls, '')
        .replaceAll(_whitespace, ' ')
        .trim();
    if (name.characters.length > _maxNameCharacters) {
      name = name.characters.take(_maxNameCharacters).toString().trim();
    }
    return name.isEmpty ? null : name;
  }
}
