import 'dart:io';

import 'package:flutter/services.dart';

typedef WindowsVersionFallback = String Function();

class WindowsVersionProvider {
  WindowsVersionProvider({
    MethodChannel? channel,
    WindowsVersionFallback? fallbackVersion,
  })  : _channel =
            channel ?? const MethodChannel('com.ssrvpn.windows/platform_info'),
        _fallbackVersion =
            fallbackVersion ?? (() => Platform.operatingSystemVersion);

  final MethodChannel _channel;
  final WindowsVersionFallback _fallbackVersion;

  Future<String> describe() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'getWindowsVersionInfo',
      );
      final info = WindowsVersionInfo.fromMap(raw);
      if (info != null) return info.describe();
    } catch (_) {
      // Diagnostics must never block core initialization. This also covers
      // older builds without the native channel and binding-free unit tests.
      // The parsed build fallback still avoids a stale Windows product name.
    }
    return WindowsVersionInfo.describeFallback(_fallbackVersion());
  }
}

class WindowsVersionInfo {
  const WindowsVersionInfo({
    required this.major,
    required this.minor,
    required this.build,
    this.displayVersion,
    this.editionId,
  });

  final int major;
  final int minor;
  final int build;
  final String? displayVersion;
  final String? editionId;

  static WindowsVersionInfo? fromMap(Map<String, Object?>? raw) {
    if (raw == null) return null;
    final major = _asInt(raw['major']);
    final minor = _asInt(raw['minor']);
    final build = _asInt(raw['build']);
    if (major == null || minor == null || build == null || build <= 0) {
      return null;
    }
    return WindowsVersionInfo(
      major: major,
      minor: minor,
      build: build,
      displayVersion: _safeLabel(raw['displayVersion']),
      editionId: _safeLabel(raw['editionId']),
    );
  }

  String describe() {
    final family = _family(major, minor, build);
    final edition = _editionName(editionId);
    final labels = <String>[
      family,
      if (edition != null) edition,
      if (displayVersion != null) displayVersion!,
    ].join(' ');
    return '$labels ($major.$minor build $build)';
  }

  static String describeFallback(String raw) {
    final normalized = raw.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    if (!normalized.toLowerCase().contains('windows')) {
      return normalized.isEmpty ? 'Windows (version unavailable)' : normalized;
    }
    final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(normalized);
    if (match == null) {
      return normalized.isEmpty ? 'Windows (version unavailable)' : normalized;
    }
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    final build = int.parse(match.group(3)!);
    return '${_family(major, minor, build)} '
        '($major.$minor build $build)';
  }

  static String _family(int major, int minor, int build) {
    if (major == 10 && minor == 0) {
      return build >= 22000 ? 'Windows 11' : 'Windows 10';
    }
    return 'Windows $major.$minor';
  }

  static String? _editionName(String? editionId) {
    switch (editionId?.toLowerCase()) {
      case 'professional':
        return 'Pro';
      case 'core':
        return 'Home';
      case 'enterprise':
        return 'Enterprise';
      case 'education':
        return 'Education';
      default:
        return editionId;
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static String? _safeLabel(Object? value) {
    final label = value?.toString().trim();
    if (label == null ||
        label.isEmpty ||
        label.length > 32 ||
        !RegExp(r'^[A-Za-z0-9._ -]+$').hasMatch(label)) {
      return null;
    }
    return label;
  }
}
