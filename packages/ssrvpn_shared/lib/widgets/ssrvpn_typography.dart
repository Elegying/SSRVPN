import 'package:flutter/foundation.dart';

/// Native sans-serif stack, matching the desktop client's system-UI policy.
abstract final class SsrvpnTypography {
  static String get family => switch (defaultTargetPlatform) {
        TargetPlatform.macOS || TargetPlatform.iOS => '.AppleSystemUIFont',
        TargetPlatform.windows => 'Segoe UI',
        _ => 'Roboto',
      };
  static List<String> get fallback => switch (defaultTargetPlatform) {
        TargetPlatform.macOS || TargetPlatform.iOS => const [
            'PingFang SC',
            'Heiti SC'
          ],
        TargetPlatform.windows => const [
            'Microsoft YaHei UI',
            'Microsoft YaHei'
          ],
        _ => const ['Noto Sans CJK SC', 'Noto Sans SC', 'sans-serif'],
      };
}
