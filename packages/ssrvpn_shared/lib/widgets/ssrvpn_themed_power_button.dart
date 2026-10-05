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
      required this.onTap,
      this.statusText});
  final double size;
  final String? statusText;
  final bool isConnected, isConnecting, hasConnectionError;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = SsrvpnTheme.of(context);
    final cloud = theme.variant == AppThemeVariant.cloud;
    final highContrast = MediaQuery.highContrastOf(context);
    final illustratedForeground = switch (theme.variant) {
      AppThemeVariant.ocean => Colors.white,
      AppThemeVariant.journal => const Color(0xFFFFF0D0),
      AppThemeVariant.orbital => const Color(0xFF20251F),
      AppThemeVariant.pixel => const Color(0xFF123C27),
      _ => theme.primary,
    };
    final foreground = hasConnectionError
        ? theme.error
        : theme.isIllustrated && !highContrast
            ? illustratedForeground
            : theme.isSoft && !isConnected
                ? theme.textSecondary
                : cloud
                    ? Colors.white
                    : theme.variant == AppThemeVariant.dusk
                        ? theme.textPrimary
                        : theme.primary;
    final insetStatus =
        theme.isIllustrated && theme.variant != AppThemeVariant.pixel;
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
                  if (theme.isIllustrated && !highContrast)
                    Positioned.fill(
                        child: AnimatedOpacity(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 180),
                            opacity: isConnected || isConnecting ? 1 : .78,
                            child: Image.asset(
                                'assets/themes/${theme.assetName}-control.webp',
                                package: 'ssrvpn_shared',
                                fit: BoxFit.contain,
                                excludeFromSemantics: true)))
                  else if (theme.isSoft && !highContrast)
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
                            decoration:
                                BoxDecoration(shape: BoxShape.circle, color: cloud ? const Color(0xFF5BB5FA) : theme.surface, border: Border.all(color: theme.textPrimary, width: 2)))),
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
                              child:
                                  Stack(alignment: Alignment.center, children: [
                                Align(
                                    alignment:
                                        Alignment(0, insetStatus ? -.18 : 0),
                                    child: isConnecting
                                        ? SizedBox.square(
                                            dimension: size * .28,
                                            child: CircularProgressIndicator(
                                                color: foreground,
                                                strokeWidth: 3))
                                        : Icon(Icons.power_settings_new_rounded,
                                            size: size * .37,
                                            color: foreground)),
                                if (insetStatus)
                                  Align(
                                      alignment: const Alignment(0, .45),
                                      child: SizedBox(
                                          width: size * .52,
                                          height: size * .12,
                                          child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Text(
                                                  statusText ??
                                                      (isConnecting
                                                          ? '正在连接'
                                                          : hasConnectionError
                                                              ? '连接异常'
                                                              : isConnected
                                                                  ? '已连接'
                                                                  : '未连接'),
                                                  style: TextStyle(
                                                      color: foreground,
                                                      fontSize: size * .065,
                                                      fontWeight:
                                                          FontWeight.w700))))),
                              ])))),
                ]))));
  }
}
