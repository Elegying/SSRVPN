import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

Future<void> showSsrvpnInfoDialog(
  BuildContext context, {
  required Key panelKey,
  required Key scrollKey,
  required IconData icon,
  required String title,
  required Widget content,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final mediaQuery = MediaQuery.of(dialogContext);
      final maxHeight =
          (mediaQuery.size.height - mediaQuery.viewInsets.vertical - 56)
              .clamp(160.0, double.infinity)
              .toDouble();
      final theme = Theme.of(dialogContext);
      final colors = theme.colorScheme;
      final isDark = theme.brightness == Brightness.dark;

      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 420, maxHeight: maxHeight),
          child: _SsrvpnModalGlassPanel(
            key: panelKey,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      key: scrollKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Column(
                            key: const Key('ssrvpn-info-dialog-header'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [colors.primary, colors.secondary],
                                  ),
                                  shape: BoxShape.circle,
                                ),
                                child:
                                    Icon(icon, color: Colors.white, size: 28),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                title,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: colors.onSurface,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          SizedBox(width: double.infinity, child: content),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        backgroundColor: colors.primary.withValues(
                          alpha: isDark ? 0.16 : 0.10,
                        ),
                        foregroundColor: colors.onSurface,
                        textStyle: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('知道了'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _SsrvpnModalGlassPanel extends StatelessWidget {
  const _SsrvpnModalGlassPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    const radius = 16.0;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.32 : 0.08),
            blurRadius: 30,
            spreadRadius: -12,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        const Color(0xFF22304A).withValues(alpha: 0.72),
                        const Color(0xFF101827).withValues(alpha: 0.78),
                        const Color(0xFF07101C).withValues(alpha: 0.82),
                        primary.withValues(alpha: 0.08),
                      ]
                    : [
                        Colors.white.withValues(alpha: 0.80),
                        Colors.white.withValues(alpha: 0.42),
                        primary.withValues(alpha: 0.08),
                      ],
                stops: isDark ? const [0.0, 0.4, 0.78, 1.0] : null,
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.72),
                width: 0.7,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
