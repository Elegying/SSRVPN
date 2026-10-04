import 'package:flutter/material.dart';
import '../models/app_settings.dart';
import 'ssrvpn_theme.dart';
import 'ssrvpn_connection_art.dart';
import 'ssrvpn_soft_power_art.dart';

/// Generated material surrounds a real focusable, cancellable connection action.
class SsrvpnThemedPowerButton extends StatelessWidget {
  const SsrvpnThemedPowerButton(
      {super.key,
      required this.size,
      required this.isConnected,
      required this.isConnecting,
      required this.hasConnectionError,
      required this.onTap});
  final double size;
  final bool isConnected, isConnecting, hasConnectionError;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = SsrvpnTheme.of(context);
    final cloud = theme.variant == AppThemeVariant.cloud;
    final highContrast = MediaQuery.highContrastOf(context);
    final foreground = hasConnectionError
        ? theme.error
        : theme.isSoft && !isConnected
            ? theme.textSecondary
            : cloud
                ? Colors.white
                : theme.variant == AppThemeVariant.dusk
                    ? theme.textPrimary
                    : theme.primary;
    final label = isConnecting
        ? '取消当前连接操作'
        : isConnected
            ? '断开连接'
            : '连接';
    return Semantics(
        button: true,
        label: label,
        child: Tooltip(
            message: label,
            child: SizedBox.square(
                dimension: size,
                child: Stack(alignment: Alignment.center, children: [
                  if (theme.isSoft && !highContrast)
                    Positioned.fill(
                        child: SsrvpnSoftPowerArt(
                            active: isConnected &&
                                !isConnecting &&
                                !hasConnectionError))
                  else if (!highContrast && !cloud)
                    Positioned.fill(
                        child: SsrvpnConnectionArtwork(
                            variant: theme.variant,
                            active: isConnected &&
                                !isConnecting &&
                                !hasConnectionError))
                  else
                    Positioned.fill(
                        child: DecoratedBox(
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: cloud
                                    ? const Color(0xFF5BB5FA)
                                    : theme.surface,
                                border: Border.all(
                                    color: theme.textPrimary, width: 2)))),
                  Positioned.fill(
                      child: Material(
                          color: Colors.transparent,
                          shape: const CircleBorder(),
                          child: InkWell(
                              splashFactory: NoSplash.splashFactory,
                              highlightColor: Colors.transparent,
                              key: const Key('ssrvpn-power-button'),
                              customBorder: const CircleBorder(),
                              onTap: onTap,
                              child: Center(
                                  child: isConnecting
                                      ? SizedBox.square(
                                          dimension: size * .28,
                                          child: CircularProgressIndicator(
                                              color: foreground,
                                              strokeWidth: 3))
                                      : Icon(Icons.power_settings_new_rounded,
                                          size: size * .37,
                                          color: foreground))))),
                ]))));
  }
}
