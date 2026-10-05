import 'ssrvpn_theme_icon.dart';
import 'ssrvpn_soft_inset.dart';
import 'ssrvpn_soft_surface.dart';
import '../models/app_settings.dart';
import 'ssrvpn_appearance.dart';
export 'ssrvpn_theme.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;
import 'ssrvpn_liquid_glass.dart';
import 'ssrvpn_glass_capture.dart';

import 'package:flutter/material.dart';

export 'ssrvpn_about_dialog.dart' show showSsrvpnAboutDialog;
export 'ssrvpn_info_dialog.dart'
    show showSsrvpnInfoDialog, SsrvpnModalGlassPanel;
import 'ssrvpn_version_update_footer.dart';
import 'ssrvpn_home_text.dart';

part 'ssrvpn_high_contrast_navigation.dart';

abstract final class SsrvpnUiTokens {
  static SsrvpnTheme of(BuildContext context) => SsrvpnTheme.of(context);
  static const background = Color(0xFF0A1020);
  static const backgroundRaised = Color(0xFF14152F);
  static const surface = Color(0xFF242641);
  static const surfaceStrong = Color(0xFF2C2E4B);
  static const primary = Color(0xFF8A84FF);
  static const primaryBlue = Color(0xFF3675FF);
  static const accent = Color(0xFF20C8B4);
  static const success = Color(0xFF29C978);
  static const warning = Color(0xFFF3B83F);
  static const error = Color(0xFFE35D6A);
  static const textPrimary = Color(0xFFF5F7FF);
  static const textSecondary = Color(0xFFA7AFC2);
  static const textTertiary = Color(0xFF929BB1);
  static const border = Color(0x33FFFFFF);

  static const pagePadding = 20.0;
  static const cardRadius = 24.0;
  static const compactBreakpoint = 460.0;
  static const pageMaxWidth = 440.0;
  static const bottomNavigationMaxWidth = 440.0;
  static const currentNodeMaxWidth = 440.0;
}

/// Shared translucent blur surface used by modal content on every platform.
class SsrvpnFrostedPanel extends StatelessWidget {
  const SsrvpnFrostedPanel({
    super.key,
    required this.child,
    this.borderRadius = 20,
    this.padding = const EdgeInsets.all(24),
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SsrvpnLiquidSurface(
        radius: borderRadius, padding: padding, child: child);
  }
}

/// Shared accepted wallpaper with a lightweight asset-error fallback.
class SsrvpnAppBackdrop extends StatelessWidget {
  const SsrvpnAppBackdrop(
      {super.key, required this.child, this.readable = false});
  final bool readable;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final theme = SsrvpnTheme.of(context);
    final shade = MediaQuery.highContrastOf(context)
        ? .82
        : readable && theme.isIllustrated
            ? (theme.isLight ? .82 : .25)
            : (theme.isDefault ? .28 : 0.0);
    return liquid.LiquidGlassScope(
      child: SsrvpnGlassCapture(
          child: Stack(fit: StackFit.expand, children: [
        Positioned.fill(
            child: IgnorePointer(
                child: SsrvpnGlassBackgroundSource(
          child: ColoredBox(
              color: theme.background,
              child: (theme.variant == AppThemeVariant.cloud || theme.isSoft)
                  ? ColoredBox(color: theme.background)
                  : Image.asset(
                      theme.wallpaper,
                      package: 'ssrvpn_shared',
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      filterQuality: FilterQuality.medium,
                      color: (theme.isLight ? Colors.white : Colors.black)
                          .withValues(alpha: shade),
                      colorBlendMode: BlendMode.srcATop,
                      errorBuilder: (_, __, ___) =>
                          ColoredBox(color: theme.background),
                    )),
        ))),
        child,
      ])),
    );
  }
}

/// Reserves the native/custom caption area without moving the app backdrop.
///
/// The window surface can therefore render edge-to-edge while widgets that use
/// [SafeArea] stay clear of the platform window controls.
class SsrvpnDesktopTitlebarInset extends StatelessWidget {
  const SsrvpnDesktopTitlebarInset({
    super.key,
    required this.top,
    required this.child,
  });

  final double top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final currentPadding = mediaQuery.padding;
    final resolvedTop = currentPadding.top > top ? currentPadding.top : top;
    return MediaQuery(
      data: mediaQuery.copyWith(
        padding: EdgeInsets.fromLTRB(
          currentPadding.left,
          resolvedTop,
          currentPadding.right,
          currentPadding.bottom,
        ),
      ),
      child: child,
    );
  }
}

class SsrvpnSurfaceCard extends StatelessWidget {
  const SsrvpnSurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = SsrvpnUiTokens.cardRadius,
    this.color,
    this.borderColor = SsrvpnUiTokens.border,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return SsrvpnLiquidSurface(
      radius: radius,
      padding: padding,
      tint: color,
      borderColor: borderColor == SsrvpnUiTokens.border ? null : borderColor,
      child: child,
    );
  }
}

class SsrvpnBottomNavigation extends StatelessWidget {
  const SsrvpnBottomNavigation({
    super.key,
    required this.currentIndex,
    required this.version,
    required this.onTap,
    this.availableVersion,
    this.onUpdateTap,
  });

  final int currentIndex;
  final String version;
  final ValueChanged<int> onTap;
  final String? availableVersion;
  final VoidCallback? onUpdateTap;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: EdgeInsets.fromLTRB(18, 8, 18, 8),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: SsrvpnUiTokens.bottomNavigationMaxWidth,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (MediaQuery.highContrastOf(context) ||
                  ssrvpnUsesLowEffects(context))
                _PlainNavigation(currentIndex: currentIndex, onTap: onTap)
              else
                liquid.GlassTabBar.bottom(
                  key: const Key('ssrvpn-bottom-navigation'),
                  selectedIndex: currentIndex,
                  onTabSelected: onTap,
                  horizontalPadding: 0,
                  verticalPadding: 0,
                  barHeight: 72,
                  barBorderRadius: 28,
                  quality: ssrvpnGlassQuality(context),
                  backgroundQuality: ssrvpnGlassQuality(context),
                  settings: SsrvpnLiquidSurface.settingsFor(context),
                  indicatorColor:
                      SsrvpnUiTokens.of(context).primary.withValues(alpha: .25),
                  indicatorExpansion: EdgeInsets.zero,
                  magnification: 1.04,
                  pressScale: 1.02,
                  selectedIconColor: SsrvpnUiTokens.of(context).textPrimary,
                  selectedLabelColor: SsrvpnUiTokens.of(context).textPrimary,
                  unselectedIconColor: SsrvpnUiTokens.of(context).textSecondary,
                  unselectedLabelColor:
                      SsrvpnUiTokens.of(context).textSecondary,
                  labelFontSize: 12,
                  iconSize: 23,
                  tabs: [
                    liquid.GlassTab(
                        icon: Icon(Icons.home_outlined),
                        activeIcon: Icon(Icons.home_rounded),
                        label: '主页'),
                    liquid.GlassTab(
                        icon: Icon(Icons.rss_feed_outlined),
                        activeIcon: Icon(Icons.rss_feed_rounded),
                        label: '订阅'),
                    liquid.GlassTab(
                        icon: Icon(Icons.settings_outlined),
                        activeIcon: Icon(Icons.settings_rounded),
                        label: '设置'),
                  ],
                ),
              SizedBox(height: 6),
              SsrvpnVersionUpdateFooter(
                version: version,
                fitHomeText: true,
                availableVersion: availableVersion,
                onUpdateTap: onUpdateTap,
                versionColor: SsrvpnUiTokens.of(context).textTertiary,
                updateLabelColor: SsrvpnUiTokens.of(context).warning,
                updateActionColor: SsrvpnUiTokens.of(context).accent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SsrvpnNavigationDestination extends StatelessWidget {
  const SsrvpnNavigationDestination({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final highContrast = MediaQuery.highContrastOf(context);
    final scheme = Theme.of(context).colorScheme;
    final pixel = SsrvpnTheme.of(context).variant == AppThemeVariant.pixel &&
        !highContrast;
    final color = pixel && selected
        ? const Color(0xFFFFB952)
        : highContrast
            ? (selected ? scheme.onPrimary : scheme.onSurface)
            : (selected
                ? SsrvpnUiTokens.of(context).textPrimary
                : SsrvpnUiTokens.of(context).textSecondary);
    final soft = SsrvpnTheme.of(context).isSoft && !highContrast;
    final destination = Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: soft || pixel
            ? Colors.transparent
            : selected
                ? (highContrast
                    ? scheme.primary
                    : SsrvpnUiTokens.of(context)
                        .primary
                        .withValues(alpha: 0.16))
                : Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SsrvpnThemeIcon(
                    label == '主页'
                        ? 'home'
                        : label == '订阅'
                            ? 'subscription'
                            : 'settings',
                    fallback: selected ? selectedIcon : icon,
                    color: color,
                    size: SsrvpnTheme.of(context).isDefault ? 23 : 32),
                SizedBox(height: 2),
                Flexible(
                    child: SsrvpnHomeText(
                  label,
                  maxFontSize: 16,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
                )),
                if (pixel)
                  Container(
                      height: 3,
                      width: 34,
                      margin: const EdgeInsets.only(top: 3),
                      color: selected
                          ? const Color(0xFFFFB952)
                          : Colors.transparent),
              ],
            ),
          ),
        ),
      ),
    );
    return soft && selected ? SsrvpnSoftInset(child: destination) : destination;
  }
}
