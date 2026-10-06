import 'ssrvpn_theme_icon.dart';
import 'package:flutter/material.dart';
import 'ssrvpn_app_surface.dart';
import 'ssrvpn_home_text.dart';

/// One persisted desktop transport choice, not two independently enabled routes.
/// Android uses VpnService and never exposes a fictitious system-proxy action.
class SsrvpnHomeModeControls extends StatelessWidget {
  const SsrvpnHomeModeControls(
      {super.key, required this.enableTun, required this.busy, this.onChanged});
  final bool enableTun, busy;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = SsrvpnTheme.of(context);
    Widget choice(bool tun) {
      final selected = enableTun == tun;
      final enabled = !busy && onChanged != null;
      final label = tun ? 'TUN 模式' : '系统代理';
      final hint = busy
          ? '正在切换连接，请稍候'
          : tun
              ? '接管设备网络；连接时可能需要系统授权'
              : '让遵循系统代理设置的应用使用代理';
      return Expanded(
          child: Tooltip(
              message: hint,
              child: Semantics(
                  label: label,
                  excludeSemantics: true,
                  onTap: enabled && !selected ? () => onChanged!(tun) : null,
                  selected: selected,
                  inMutuallyExclusiveGroup: true,
                  enabled: enabled,
                  button: true,
                  child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        key: ValueKey(
                            tun ? 'home-tun-mode' : 'home-system-proxy'),
                        borderRadius: BorderRadius.circular(16),
                        onTap:
                            enabled && !selected ? () => onChanged!(tun) : null,
                        child: SsrvpnSurfaceCard(
                            radius: 16,
                            color: selected
                                ? theme.primary.withValues(alpha: .16)
                                : null,
                            borderColor:
                                selected ? theme.primary : theme.border,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 10),
                            child: Row(children: [
                              SsrvpnThemeIcon(tun ? 'tun' : 'system-proxy',
                                  fallback: tun
                                      ? Icons.hub_outlined
                                      : Icons.desktop_windows_outlined,
                                  size: 20,
                                  color: selected
                                      ? theme.primary
                                      : theme.textSecondary),
                              const SizedBox(width: 7),
                              Expanded(
                                  child: SsrvpnHomeText(label,
                                      maxFontSize: 14,
                                      style: TextStyle(
                                          color: theme.textPrimary,
                                          fontSize: 14,
                                          fontWeight: selected
                                              ? FontWeight.w700
                                              : FontWeight.w600))),
                              Icon(
                                  selected
                                      ? Icons.check_circle_rounded
                                      : Icons.circle_outlined,
                                  size: 16,
                                  color: selected
                                      ? theme.primary
                                      : theme.textSecondary),
                            ])),
                      )))));
    }

    return SizedBox(
        height: 48,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          choice(false),
          const SizedBox(width: 8),
          choice(true),
        ]));
  }
}

class SsrvpnPublicIpCard extends StatelessWidget {
  const SsrvpnPublicIpCard(
      {super.key,
      this.value,
      this.error,
      this.busy = false,
      required this.refreshing,
      required this.onRefresh});
  final String? value, error;
  final bool refreshing, busy;
  final VoidCallback onRefresh;
  @override
  Widget build(BuildContext context) {
    final theme = SsrvpnTheme.of(context);
    final label = refreshing
        ? '正在获取公网 IPv4…'
        : error ?? (value == null ? '获取公网 IPv4' : '公网 IPv4  $value');
    return Semantics(
        label: label,
        excludeSemantics: true,
        onTap: refreshing || busy ? null : onRefresh,
        button: true,
        enabled: !busy && !refreshing,
        liveRegion: true,
        child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: const Key('home-public-ip'),
              borderRadius: BorderRadius.circular(16),
              onTap: refreshing || busy ? null : onRefresh,
              child: SsrvpnSurfaceCard(
                  radius: 16,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  child: Row(children: [
                    refreshing
                        ? SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: theme.primary))
                        : SsrvpnThemeIcon('public-ip',
                            fallback: Icons.public_rounded,
                            size: 19,
                            color: theme.primary),
                    const SizedBox(width: 9),
                    Expanded(
                        child: SsrvpnHomeText(label,
                            maxFontSize: 15,
                            maxLines: 1,
                            style: TextStyle(
                                color: error == null
                                    ? theme.textPrimary
                                    : theme.warning,
                                fontSize: 15,
                                fontWeight: FontWeight.w600))),
                    const SizedBox(width: 4),
                    Icon(Icons.refresh_rounded,
                        size: 17, color: theme.textSecondary),
                  ])),
            )));
  }
}
