import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import '../models/app_settings.dart';
import 'ssrvpn_theme.dart';
export 'ssrvpn_theme.dart';

/// Keep the navigator and forms mounted while changing the captured theme.
class SsrvpnAppearanceScope extends StatelessWidget {
  const SsrvpnAppearanceScope(
      {super.key, required this.settings, required this.child});
  final AppSettings settings;
  final Widget child;
  @override
  Widget build(BuildContext context) => Theme(
        data: SsrvpnTheme(settings.themeVariant).material(Theme.of(context)),
        child: glass.GlassAdaptiveScope(
          minQuality: glass.GlassQuality.premium,
          maxQuality: glass.GlassQuality.premium,
          initialQuality: glass.GlassQuality.premium,
          child: child,
        ),
      );
}
