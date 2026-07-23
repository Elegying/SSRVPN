import 'package:flutter/material.dart';

import '../constants/app_constants.dart';

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
  });

  final int currentIndex;
  final String version;
  final ValueChanged<int> onTap;

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
              Text(
                '版本号：$version',
                style: const TextStyle(
                  color: SsrvpnUiTokens.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                  decoration: TextDecoration.none,
                ),
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

Future<void> showSsrvpnAboutDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      backgroundColor: SsrvpnUiTokens.backgroundRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Row(
        children: [
          Icon(Icons.vpn_lock_rounded, color: SsrvpnUiTokens.primary),
          SizedBox(width: 10),
          Text('SSRVPN'),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '版本 ${AppConstants.appVersion}',
              style: TextStyle(color: SsrvpnUiTokens.primary),
            ),
            const SizedBox(height: 16),
            const Text('项目地址', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            SelectableText(
              'https://github.com/Elegying/SSRVPN',
              style: TextStyle(color: SsrvpnUiTokens.primaryBlue),
            ),
            const SizedBox(height: 16),
            const Text('免责声明', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
              '本软件仅供学习与研究使用，请遵守当地法律法规。\n'
              '使用者应对自身行为承担全部责任。\n'
              '开发者不对因使用本软件产生的任何后果负责。',
              style: TextStyle(
                color: SsrvpnUiTokens.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'By--两颗西柚',
              style: TextStyle(color: SsrvpnUiTokens.textSecondary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
