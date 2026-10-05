part of 'ssrvpn_home_overview.dart';

class SsrvpnPowerButton extends StatelessWidget {
  const SsrvpnPowerButton({
    super.key,
    required this.size,
    required this.isConnected,
    required this.isConnecting,
    required this.onTap,
    this.hasConnectionError = false,
    this.statusText,
  });

  final double size;
  final String? statusText;
  final bool isConnected;
  final bool isConnecting;
  final bool hasConnectionError;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!SsrvpnTheme.of(context).isDefault) {
      return SsrvpnThemedPowerButton(
          size: size,
          statusText: statusText,
          isConnected: isConnected,
          isConnecting: isConnecting,
          hasConnectionError: hasConnectionError,
          onTap: onTap);
    }
    final activeColor = hasConnectionError
        ? SsrvpnUiTokens.of(context).error
        : isConnected
            ? SsrvpnUiTokens.of(context).success
            : SsrvpnUiTokens.of(context).primary;
    final semanticLabel = isConnecting
        ? '取消当前连接操作'
        : isConnected
            ? '断开连接'
            : '连接';
    return SsrvpnConnectionHalo(
      enabled: isConnected &&
          !isConnecting &&
          !hasConnectionError &&
          !ssrvpnUsesLowEffects(context) &&
          !MediaQuery.highContrastOf(context),
      size: size,
      color: activeColor,
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: Material(
          key: Key('ssrvpn-power-button'),
          color: Colors.transparent,
          shape: CircleBorder(),
          child: InkWell(
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.transparent,
            customBorder: CircleBorder(),
            onTap: onTap,
            child: Container(
              width: size,
              height: size,
              padding: EdgeInsets.all(size * 0.075),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color:
                      activeColor.withValues(alpha: isConnected ? 0.62 : 0.28),
                  width: 2,
                ),
                boxShadow: ssrvpnUsesLowEffects(context)
                    ? []
                    : [
                        BoxShadow(
                          color: activeColor.withValues(
                              alpha: isConnected ? 0.28 : 0.12),
                          blurRadius: 38,
                          spreadRadius: 3,
                        ),
                      ],
              ),
              child: SsrvpnLiquidSurface(
                circular: true,
                tint: activeColor,
                borderColor: activeColor.withValues(alpha: .35),
                child: Center(
                  child: isConnecting
                      ? SizedBox(
                          width: size * 0.3,
                          height: size * 0.3,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: activeColor,
                          ),
                        )
                      : Icon(
                          Icons.power_settings_new_rounded,
                          size: size * 0.36,
                          color: isConnected
                              ? activeColor
                              : SsrvpnUiTokens.of(context).textSecondary,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
