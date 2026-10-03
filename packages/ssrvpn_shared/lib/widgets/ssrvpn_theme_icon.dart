import 'package:flutter/material.dart';
import 'ssrvpn_theme.dart';

/// Decorative theme artwork; surrounding controls retain their own semantics.
/// Default uses artwork only for the subscription heading; high contrast uses glyphs.
class SsrvpnThemeIcon extends StatelessWidget {
  const SsrvpnThemeIcon(this.name,
      {super.key, required this.fallback, this.size = 24, this.color});
  final String name;
  final IconData fallback;
  final double size;
  final Color? color;

  static const names = [
    'home',
    'subscription',
    'settings',
    'upload',
    'download',
    'total',
    'devices',
    'subscription-header',
    'add',
    'logs',
    'appearance',
    'diagnostic',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = SsrvpnTheme.of(context);
    Widget glyph() => Icon(fallback, size: size, color: color);
    if ((theme.isDefault && name != 'subscription-header') ||
        MediaQuery.highContrastOf(context)) {
      return glyph();
    }
    return Image.asset('assets/themes/${theme.assetName}-$name.webp',
        package: 'ssrvpn_shared',
        width: size,
        height: size,
        excludeFromSemantics: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => glyph());
  }
}
