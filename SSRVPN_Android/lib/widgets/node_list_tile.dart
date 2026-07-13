import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';

/// 节点卡片组件 — 单个代理节点行
///
/// 从 home_screen.dart 拆分，包含国旗标识、节点信息、延迟显示、上下文菜单
class NodeListTile extends StatelessWidget {
  final ProxyNode node;
  final int? latency;
  final bool isTesting;
  final bool isSelected;
  final bool isTimeout;
  final bool isConnected;
  final VoidCallback onTestLatency;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onEdit;
  final Color textColor;
  final Color subColor;
  final bool isDark;

  const NodeListTile({
    super.key,
    required this.node,
    required this.latency,
    required this.isTesting,
    required this.isSelected,
    required this.isTimeout,
    required this.isConnected,
    required this.onTestLatency,
    required this.onTap,
    required this.onLongPress,
    this.onEdit,
    required this.textColor,
    required this.subColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveTextColor =
        isTimeout ? textColor.withValues(alpha: 80 / 255) : textColor;
    final effectiveSubColor =
        isTimeout ? subColor.withValues(alpha: 60 / 255) : subColor;
    final flagInfo = _parseFlag(node.name);

    return Padding(
      padding: EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: isTimeout ? null : onTap,
        onLongPress: onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: isSelected
                ? (isDark
                    ? AppTheme.successColor.withValues(alpha: 15 / 255)
                    : AppTheme.successColor.withValues(alpha: 10 / 255))
                : null,
            border: Border.all(
              color: isSelected
                  ? AppTheme.successColor.withValues(alpha: 80 / 255)
                  : isDark
                      ? AppTheme.darkBorder
                      : AppTheme.lightBorder,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Opacity(
            opacity: isTimeout ? 0.45 : 1.0,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  // 国旗标识
                  _FlagAvatar(
                    flag: flagInfo.flag,
                    isSelected: isSelected,
                    isTimeout: isTimeout,
                    initial: node.name.characters.first,
                  ),
                  SizedBox(width: 8),
                  // 节点信息
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (flagInfo.flag.isNotEmpty) ...[
                              Text(
                                flagInfo.flag,
                                style: TextStyle(fontSize: Responsive.sp(13)),
                              ),
                              SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                flagInfo.cleanName,
                                style: TextStyle(
                                  fontSize: Responsive.sp(13),
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: isSelected
                                      ? AppTheme.successColor
                                      : effectiveTextColor,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 2),
                        Row(
                          children: [
                            _TypeBadge(type: node.type, isTimeout: isTimeout),
                            SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${node.server.contains(':') ? '[${node.server}]' : node.server}:${node.port}',
                                style: TextStyle(
                                  fontSize: Responsive.sp(10),
                                  color: effectiveSubColor,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // 延迟显示 / 测速中指示器（替代原来的三个点）
                  if (true) ...[
                    // 延迟
                    if (isTesting)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.primaryColor,
                        ),
                      )
                    else if (isTimeout)
                      const _LatencyBadge(latency: 65535)
                    else if (latency != null && latency! > 0)
                      _LatencyBadge(latency: latency!)
                    else if (isConnected)
                      GestureDetector(
                        onTap: onTestLatency,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor
                                .withValues(alpha: 15 / 255),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '测速',
                            style: TextStyle(
                              fontSize: Responsive.sp(10),
                              color: AppTheme.primaryColor
                                  .withValues(alpha: 200 / 255),
                            ),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 从节点名称解析国旗和清理后的名称
  _FlagInfo _parseFlag(String name) {
    if (name.length >= 2) {
      final first = name.codeUnitAt(0);
      final second = name.codeUnitAt(1);
      if (first >= 0x1F1E6 &&
          first <= 0x1F1FF &&
          second >= 0x1F1E6 &&
          second <= 0x1F1FF) {
        final flag = name.substring(0, 2);
        var clean = name.substring(2).trimLeft();
        if (clean.startsWith('-') ||
            clean.startsWith('–') ||
            clean.startsWith('—')) {
          clean = clean.substring(1).trimLeft();
        }
        return _FlagInfo(flag: flag, cleanName: clean);
      }
    }
    final isoPrefix = RegExp(
      r'^(US|UK|GB|JP|KR|HK|TW|SG|DE|FR|NL|CA|AU|IN|TH|VN|ID|PH|MY|RU|TR|BR|AR|MX|ZA|IT|ES|SE|NO|FI|DK|IE|CH|AT|BE|PL|UA|CL|CO|PE)\s*[-–—]\s*',
    );
    final isoMatch = isoPrefix.firstMatch(name);
    if (isoMatch != null) {
      return _FlagInfo(
        flag: _countryCodeToFlag(isoMatch.group(1)!),
        cleanName: name.substring(isoMatch.end).trim(),
      );
    }
    return _FlagInfo(flag: '', cleanName: name);
  }

  static String _countryCodeToFlag(String code) {
    const map = {
      'US': '🇺🇸',
      'UK': '🇬🇧',
      'GB': '🇬🇧',
      'JP': '🇯🇵',
      'KR': '🇰🇷',
      'HK': '🇭🇰',
      'TW': '🇨🇳',
      'SG': '🇸🇬',
      'DE': '🇩🇪',
      'FR': '🇫🇷',
      'NL': '🇳🇱',
      'CA': '🇨🇦',
      'AU': '🇦🇺',
      'IN': '🇮🇳',
      'TH': '🇹🇭',
      'VN': '🇻🇳',
      'ID': '🇮🇩',
      'PH': '🇵🇭',
      'MY': '🇲🇾',
      'RU': '🇷🇺',
      'TR': '🇹🇷',
      'BR': '🇧🇷',
      'AR': '🇦🇷',
      'MX': '🇲🇽',
      'ZA': '🇿🇦',
      'IT': '🇮🇹',
      'ES': '🇪🇸',
      'SE': '🇸🇪',
      'NO': '🇳🇴',
      'FI': '🇫🇮',
      'DK': '🇩🇰',
      'IE': '🇮🇪',
      'CH': '🇨🇭',
      'AT': '🇦🇹',
      'BE': '🇧🇪',
      'PL': '🇵🇱',
      'UA': '🇺🇦',
      'CL': '🇨🇱',
      'CO': '🇨🇴',
      'PE': '🇵🇪',
    };
    return map[code] ?? '';
  }
}

class _FlagInfo {
  final String flag;
  final String cleanName;
  _FlagInfo({required this.flag, required this.cleanName});
}

class _FlagAvatar extends StatelessWidget {
  final String flag;
  final bool isSelected;
  final bool isTimeout;
  final String initial;

  const _FlagAvatar({
    required this.flag,
    required this.isSelected,
    required this.isTimeout,
    required this.initial,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: isSelected
            ? AppTheme.successColor.withValues(alpha: 25 / 255)
            : isTimeout
                ? AppTheme.errorColor.withValues(alpha: 8 / 255)
                : AppTheme.primaryColor.withValues(alpha: 15 / 255),
        borderRadius: BorderRadius.circular(isSelected ? 10 : 8),
        border: Border.all(
          color: isSelected
              ? AppTheme.successColor.withValues(alpha: 60 / 255)
              : Colors.transparent,
          width: isSelected ? 1.2 : 0,
        ),
      ),
      child: isSelected
          ? Center(
              child: Icon(
                Icons.check_circle,
                size: Responsive.icon(16),
                color: AppTheme.successColor,
              ),
            )
          : flag.isNotEmpty
              ? Center(
                  child: Text(
                    flag,
                    style: TextStyle(fontSize: Responsive.sp(14)),
                  ),
                )
              : Center(
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontSize: Responsive.sp(11),
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primaryColor,
                    ),
                  ),
                ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final String type;
  final bool isTimeout;
  const _TypeBadge({required this.type, this.isTimeout = false});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final display = type.toUpperCase().length > 4
        ? type.toUpperCase().substring(0, 4)
        : type.toUpperCase();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppTheme.primaryColor.withValues(
          alpha: (isTimeout ? 8 : (isDark ? 20 : 15)) / 255,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        display,
        style: TextStyle(
          fontSize: Responsive.sp(8),
          fontWeight: FontWeight.w700,
          color: AppTheme.primaryColor
              .withValues(alpha: (isTimeout ? 100 : 255) / 255),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _LatencyBadge extends StatelessWidget {
  final int latency;
  const _LatencyBadge({required this.latency});

  bool get isTimeout => latency <= 0 || latency >= 65535;

  @override
  Widget build(BuildContext context) {
    final color = isTimeout
        ? AppTheme.errorColor
        : latency < 200
            ? AppTheme.successColor
            : latency < 500
                ? AppTheme.warningColor
                : AppTheme.errorColor;
    final text = isTimeout ? '超时' : '${latency}ms';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 15 / 255),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: Responsive.sp(10),
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
