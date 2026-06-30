import 'package:flutter/material.dart';
import '../models/app_settings.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';

/// 代理模式选择器
///
/// 从 home_screen.dart 拆分，提供「规则/全局」双模式切换
class ProxyModeSelector extends StatelessWidget {
  final bool isDark;
  final AppSettings settings;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const ProxyModeSelector({
    super.key,
    required this.isDark,
    required this.settings,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 5 / 255)
            : Colors.black.withValues(alpha: 5 / 255),
        borderRadius: BorderRadius.circular(Responsive.radius(12)),
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          _ProxyModeOption(
            label: '规则',
            icon: Icons.route_rounded,
            selected: settings.proxyMode == ProxyMode.rule,
            enabled: enabled,
            onTap: () => onChanged('rule'),
          ),
          SizedBox(width: 4),
          _ProxyModeOption(
            label: '全局',
            icon: Icons.public_rounded,
            selected: settings.proxyMode == ProxyMode.global,
            enabled: enabled,
            onTap: () => onChanged('global'),
          ),
        ],
      ),
    );
  }
}

class _ProxyModeOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _ProxyModeOption({
    required this.label,
    required this.icon,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(Responsive.radius(9)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 38,
          decoration: BoxDecoration(
            color: selected ? AppTheme.primaryColor : Colors.transparent,
            borderRadius: BorderRadius.circular(Responsive.radius(9)),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: AppTheme.primaryColor.withValues(alpha: 55 / 255),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected
                    ? Colors.white
                    : isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
              ),
              SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: Responsive.sp(13),
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? Colors.white
                      : isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
