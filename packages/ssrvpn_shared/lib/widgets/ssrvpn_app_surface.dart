import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

export 'ssrvpn_about_dialog.dart' show showSsrvpnAboutDialog;
export 'ssrvpn_info_dialog.dart' show showSsrvpnInfoDialog;
import 'ssrvpn_version_update_footer.dart';

abstract final class SsrvpnUiTokens {
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
  static const bottomNavigationMaxWidth = 380.0;
  static const currentNodeMaxWidth = 320.0;
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (isDark ? SsrvpnUiTokens.surface : Colors.white)
                .withValues(alpha: isDark ? 0.72 : 0.78),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: isDark ? 0.18 : 0.48),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x52000000),
                blurRadius: 32,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class SsrvpnAppBackdrop extends StatelessWidget {
  const SsrvpnAppBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF181B3B),
            SsrvpnUiTokens.background,
            Color(0xFF09152A),
          ],
          stops: [0, 0.48, 1],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(1.05, -0.1),
                  radius: 0.9,
                  colors: [Color(0x332B4D9E), Colors.transparent],
                ),
              ),
            ),
          ),
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0.95, 0.35),
                  radius: 0.75,
                  colors: [Color(0x2410B9C4), Colors.transparent],
                ),
              ),
            ),
          ),
          child,
        ],
      ),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? SsrvpnUiTokens.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor),
        boxShadow: const [
          BoxShadow(
            color: Color(0x38000000),
            blurRadius: 28,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Padding(padding: padding, child: child),
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
      minimum: const EdgeInsets.fromLTRB(18, 8, 18, 8),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: SsrvpnUiTokens.bottomNavigationMaxWidth,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                key: const Key('ssrvpn-bottom-navigation'),
                constraints: const BoxConstraints(minHeight: 72),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xF024263A),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: SsrvpnUiTokens.border),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 30,
                      spreadRadius: 1,
                      offset: Offset(0, 16),
                    ),
                    BoxShadow(
                      color: Color(0x242F5BFF),
                      blurRadius: 20,
                      spreadRadius: 1,
                      offset: Offset(0, 5),
                    ),
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 6,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SsrvpnNavigationDestination(
                        icon: Icons.home_outlined,
                        selectedIcon: Icons.home_rounded,
                        label: '主页',
                        selected: currentIndex == 0,
                        onTap: () => onTap(0),
                      ),
                    ),
                    Expanded(
                      child: SsrvpnNavigationDestination(
                        icon: Icons.rss_feed_outlined,
                        selectedIcon: Icons.rss_feed_rounded,
                        label: '订阅',
                        selected: currentIndex == 1,
                        onTap: () => onTap(1),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              SsrvpnVersionUpdateFooter(
                version: version,
                availableVersion: availableVersion,
                onUpdateTap: onUpdateTap,
                versionColor: SsrvpnUiTokens.textTertiary,
                updateLabelColor: SsrvpnUiTokens.warning,
                updateActionColor: SsrvpnUiTokens.accent,
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
    final color =
        selected ? SsrvpnUiTokens.textPrimary : SsrvpnUiTokens.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected
            ? SsrvpnUiTokens.primary.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(selected ? selectedIcon : icon, color: color, size: 23),
                const SizedBox(height: 2),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
