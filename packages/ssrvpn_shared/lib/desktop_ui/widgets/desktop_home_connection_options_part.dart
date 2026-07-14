part of desktop_home_screen;

class _DesktopConnectionOptions extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final Color subColor;
  final AppSettings settings;
  final bool isConnecting;
  final ValueChanged<ProxyMode> onProxyModeChanged;
  final ValueChanged<bool> onEnableTunChanged;

  const _DesktopConnectionOptions({
    required this.isDark,
    required this.textColor,
    required this.subColor,
    required this.settings,
    required this.isConnecting,
    required this.onProxyModeChanged,
    required this.onEnableTunChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 4 / 255)
            : Colors.black.withValues(alpha: 4 / 255),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? AppTheme.border : AppTheme.lightBorder,
          width: 0.5,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final modeControl = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '代理模式',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              _DesktopOptionChoice<ProxyMode>(
                selected: settings.proxyMode == ProxyMode.rule,
                value: ProxyMode.rule,
                enabled: !isConnecting,
                icon: Icons.route_rounded,
                label: '规则模式（默认）',
                isDark: isDark,
                textColor: textColor,
                subColor: subColor,
                onChanged: onProxyModeChanged,
              ),
              _DesktopOptionChoice<ProxyMode>(
                selected: settings.proxyMode == ProxyMode.global,
                value: ProxyMode.global,
                enabled: !isConnecting,
                icon: Icons.public_rounded,
                label: '全局模式',
                isDark: isDark,
                textColor: textColor,
                subColor: subColor,
                onChanged: onProxyModeChanged,
              ),
            ],
          );

          final tunControl = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '代理方式',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              _DesktopOptionChoice<bool>(
                selected: !settings.enableTun,
                value: false,
                enabled: !isConnecting,
                icon: Icons.language_rounded,
                label: '系统代理（默认）',
                isDark: isDark,
                textColor: textColor,
                subColor: subColor,
                onChanged: onEnableTunChanged,
              ),
              _DesktopOptionChoice<bool>(
                selected: settings.enableTun,
                value: true,
                enabled: !isConnecting,
                icon: Icons.wifi_tethering_rounded,
                label: desktopPlatformLabel == 'MacOS'
                    ? 'TUN 模式（连接时需管理员授权）'
                    : 'TUN 模式（需管理员权限）',
                isDark: isDark,
                textColor: textColor,
                subColor: subColor,
                onChanged: onEnableTunChanged,
              ),
            ],
          );

          if (constraints.maxWidth < 300) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [modeControl, const SizedBox(height: 12), tunControl],
            );
          }

          return Row(
            children: [
              Expanded(child: modeControl),
              Container(
                width: 1,
                height: 52,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                color: isDark ? AppTheme.border : AppTheme.lightBorder,
              ),
              Expanded(child: tunControl),
            ],
          );
        },
      ),
    );
  }
}

class _DesktopOptionChoice<T> extends StatelessWidget {
  final bool selected;
  final T value;
  final bool enabled;
  final IconData icon;
  final String label;
  final bool isDark;
  final Color textColor;
  final Color subColor;
  final ValueChanged<T> onChanged;

  const _DesktopOptionChoice({
    required this.selected,
    required this.value,
    required this.enabled,
    required this.icon,
    required this.label,
    required this.isDark,
    required this.textColor,
    required this.subColor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = !enabled || selected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: disabled ? null : () => onChanged(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primary.withValues(alpha: (isDark ? 28 : 18) / 255)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? AppTheme.primary.withValues(alpha: 120 / 255)
                : (isDark ? AppTheme.border : AppTheme.lightBorder),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: selected ? AppTheme.primary : subColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.25,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppTheme.primary : textColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 18,
              color: selected ? AppTheme.primary : subColor,
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopForceProxyButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool enabled;

  const _DesktopForceProxyButton({required this.onTap, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 168),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: (isDark ? 24 : 16) / 255),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: AppTheme.primary.withValues(
                alpha: (isDark ? 70 : 55) / 255,
              ),
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_link_rounded, size: 16, color: AppTheme.primary),
              SizedBox(width: 6),
              Flexible(
                child: Text(
                  '添加强制代理网站',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
