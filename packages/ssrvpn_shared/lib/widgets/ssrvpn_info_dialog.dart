import 'ssrvpn_liquid_glass.dart';

import 'package:flutter/material.dart';

final _openInfoPanels = Expando<Set<Key>>('ssrvpn info panels');

Future<void> showSsrvpnInfoDialog(
  BuildContext context, {
  required Key panelKey,
  required Key scrollKey,
  required IconData icon,
  required String title,
  required Widget content,
  String buttonLabel = '知道了',
  VoidCallback? onConfirm,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final panels = _openInfoPanels[navigator] ??= <Key>{};
  if (!panels.add(panelKey)) return;
  try {
    await showDialog<void>(
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
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 420, maxHeight: maxHeight),
            child: SsrvpnModalGlassPanel(
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
                                      colors: [
                                        colors.primary,
                                        colors.secondary
                                      ],
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
                        onPressed: () {
                          onConfirm?.call();
                          Navigator.pop(dialogContext);
                        },
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
                        child: Text(buttonLabel),
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
  } finally {
    panels.remove(panelKey);
  }
}

class SsrvpnModalGlassPanel extends StatelessWidget {
  const SsrvpnModalGlassPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = 16,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return SsrvpnLiquidSurface(
      radius: borderRadius,
      padding: padding,
      child: child,
    );
  }
}
