import 'package:flutter/material.dart';

import '../models/proxy_node.dart';
import '../utils/node_country_policy.dart';
import '../utils/node_display_policy.dart';
import 'country_flag_icon.dart';
import 'ssrvpn_app_surface.dart';

class SsrvpnHomeOverview extends StatelessWidget {
  const SsrvpnHomeOverview({
    super.key,
    required this.isConnected,
    required this.isConnecting,
    required this.selectedNode,
    required this.selectedLatency,
    required this.selectedCountryCode,
    required this.onToggleConnection,
    required this.onOpenNodes,
    required this.onShowAbout,
    required this.onShowTutorial,
    required this.onShowLogs,
    required this.onRefreshPublicIp,
    this.errorMessage,
    this.connectionNotice,
    this.publicIpv4,
    this.publicIpError,
    this.isRefreshingPublicIp = false,
  });

  final bool isConnected;
  final bool isConnecting;
  final ProxyNode? selectedNode;
  final int? selectedLatency;
  final String? selectedCountryCode;
  final String? errorMessage;
  final String? connectionNotice;
  final String? publicIpv4;
  final String? publicIpError;
  final bool isRefreshingPublicIp;
  final VoidCallback onToggleConnection;
  final VoidCallback onOpenNodes;
  final VoidCallback onShowAbout;
  final VoidCallback onShowTutorial;
  final VoidCallback onShowLogs;
  final VoidCallback onRefreshPublicIp;

  String get _statusText {
    if (isConnecting) return isConnected ? '正在断开' : '正在连接';
    if (errorMessage != null) return '连接异常';
    if (isConnected && connectionNotice != null) return '节点恢复中';
    if (isConnected) return '已连接';
    return '未连接';
  }

  Color get _statusColor {
    if (isConnecting) return SsrvpnUiTokens.warning;
    if (errorMessage != null) return SsrvpnUiTokens.error;
    if (isConnected && connectionNotice != null) return SsrvpnUiTokens.warning;
    if (isConnected) return SsrvpnUiTokens.success;
    return SsrvpnUiTokens.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < SsrvpnUiTokens.compactBreakpoint;
          final short = constraints.maxHeight < 610;
          final horizontalPadding = compact ? 18.0 : 28.0;
          final powerSize = short ? 138.0 : (compact ? 166.0 : 184.0);
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              short ? 6 : 14,
              horizontalPadding,
              24,
            ),
            child: Center(
              child: ConstrainedBox(
                key: const Key('ssrvpn-home-content'),
                constraints: const BoxConstraints(
                  maxWidth: SsrvpnUiTokens.pageMaxWidth,
                ),
                child: Column(
                  children: [
                    _HomeHeader(
                      compact: compact,
                      onShowAbout: onShowAbout,
                      onShowTutorial: onShowTutorial,
                    ),
                    SizedBox(height: short ? 6 : 10),
                    _ConnectionStatusPill(
                      label: _statusText,
                      color: _statusColor,
                    ),
                    SizedBox(height: short ? 20 : 42),
                    SsrvpnPowerButton(
                      size: powerSize,
                      isConnected: isConnected,
                      isConnecting: isConnecting,
                      hasConnectionError: errorMessage != null,
                      onTap: onToggleConnection,
                    ),
                    SizedBox(height: short ? 26 : 58),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth:
                            compact ? 300 : SsrvpnUiTokens.currentNodeMaxWidth,
                      ),
                      child: SsrvpnCurrentNodeCard(
                        node: selectedNode,
                        latency: selectedLatency,
                        countryCode: selectedCountryCode,
                        compact: compact,
                        onTap: onOpenNodes,
                      ),
                    ),
                    if (isConnected ||
                        errorMessage != null ||
                        connectionNotice != null) ...[
                      const SizedBox(height: 14),
                      _ConnectionDetails(
                        errorMessage: errorMessage,
                        connectionNotice: connectionNotice,
                        publicIpv4: publicIpv4,
                        publicIpError: publicIpError,
                        isRefreshingPublicIp: isRefreshingPublicIp,
                        onShowLogs: onShowLogs,
                        onRefreshPublicIp: onRefreshPublicIp,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.compact,
    required this.onShowAbout,
    required this.onShowTutorial,
  });

  final bool compact;
  final VoidCallback onShowAbout;
  final VoidCallback onShowTutorial;

  @override
  Widget build(BuildContext context) {
    final actionStyle = TextButton.styleFrom(
      foregroundColor: SsrvpnUiTokens.textSecondary,
      padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 10, vertical: 8),
      minimumSize: const Size(48, 40),
    );
    final title = Text(
      'SSRVPN',
      style: TextStyle(
        color: SsrvpnUiTokens.textPrimary,
        fontSize: compact ? 29 : 34,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.4,
      ),
    );
    final actions = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Tooltip(
          message: '关于',
          child: TextButton(
            key: const Key('ssrvpn-about-button'),
            onPressed: onShowAbout,
            style: actionStyle,
            child: const Text('关于'),
          ),
        ),
        Tooltip(
          message: '使用教程',
          child: TextButton(
            key: const Key('ssrvpn-tutorial-button'),
            onPressed: onShowTutorial,
            style: actionStyle,
            child: const Text('使用教程'),
          ),
        ),
      ],
    );
    final scaledTitleSize = MediaQuery.textScalerOf(context).scale(
      compact ? 29 : 34,
    );
    if (scaledTitleSize > (compact ? 39 : 46)) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          title,
          const SizedBox(height: 2),
          actions,
        ],
      );
    }
    return SizedBox(
      height: 54,
      child: Stack(
        alignment: Alignment.center,
        children: [
          actions,
          IgnorePointer(child: title),
        ],
      ),
    );
  }
}

class _ConnectionStatusPill extends StatelessWidget {
  const _ConnectionStatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      label: '连接状态：$label',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: SsrvpnUiTokens.surface.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SsrvpnPowerButton extends StatelessWidget {
  const SsrvpnPowerButton({
    super.key,
    required this.size,
    required this.isConnected,
    required this.isConnecting,
    required this.onTap,
    this.hasConnectionError = false,
  });

  final double size;
  final bool isConnected;
  final bool isConnecting;
  final bool hasConnectionError;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final activeColor = hasConnectionError
        ? SsrvpnUiTokens.error
        : isConnected
            ? SsrvpnUiTokens.success
            : SsrvpnUiTokens.primary;
    final semanticLabel = isConnecting
        ? '取消当前连接操作'
        : isConnected
            ? '断开连接'
            : '连接';
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        key: const Key('ssrvpn-power-button'),
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            padding: EdgeInsets.all(size * 0.075),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: activeColor.withValues(alpha: isConnected ? 0.62 : 0.28),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color:
                      activeColor.withValues(alpha: isConnected ? 0.28 : 0.12),
                  blurRadius: 38,
                  spreadRadius: 3,
                ),
              ],
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: isConnected
                    ? activeColor.withValues(alpha: 0.2)
                    : const Color(0xFF202B4B),
                shape: BoxShape.circle,
              ),
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
                            : SsrvpnUiTokens.textSecondary,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SsrvpnCurrentNodeCard extends StatelessWidget {
  const SsrvpnCurrentNodeCard({
    super.key,
    required this.node,
    required this.latency,
    required this.countryCode,
    required this.onTap,
    this.compact = false,
  });

  final ProxyNode? node;
  final int? latency;
  final String? countryCode;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final displayName =
        node == null ? '暂无可用节点' : nodeDisplayNameWithoutLeadingFlag(node!.name);
    final resolvedCode =
        countryCode ?? (node == null ? 'UN' : countryCodeForProxyNode(node!));
    final latencyTimedOut = NodeDisplayPolicy.isTimeoutLatency(latency);
    final latencyText = latency == null
        ? '--'
        : latencyTimedOut
            ? '超时'
            : '${latency}ms';
    final Color latencyColor;
    if (latency == null) {
      latencyColor = SsrvpnUiTokens.textSecondary;
    } else if (latencyTimedOut || latency! >= 350) {
      latencyColor = SsrvpnUiTokens.error;
    } else if (latency! < 180) {
      latencyColor = SsrvpnUiTokens.success;
    } else {
      latencyColor = SsrvpnUiTokens.warning;
    }
    final radius = compact ? 22.0 : 26.0;
    final iconSize = compact ? 48.0 : 58.0;
    return Semantics(
      button: true,
      label: node == null ? '选择服务器' : '当前节点 $displayName，打开服务器选择',
      child: Material(
        key: const Key('ssrvpn-current-node-card'),
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onTap,
          child: SsrvpnSurfaceCard(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 16 : 22,
              vertical: compact ? 14 : 18,
            ),
            radius: radius,
            child: Row(
              children: [
                Container(
                  width: iconSize,
                  height: iconSize,
                  decoration: BoxDecoration(
                    color: SsrvpnUiTokens.primary,
                    borderRadius: BorderRadius.circular(compact ? 15 : 17),
                    boxShadow: [
                      BoxShadow(
                        color: SsrvpnUiTokens.primary.withValues(alpha: 0.28),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    color: Colors.white,
                    size: compact ? 24 : 26,
                  ),
                ),
                SizedBox(width: compact ? 12 : 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '当前节点',
                        style: TextStyle(
                          color: SsrvpnUiTokens.textSecondary,
                          fontSize: compact ? 12 : 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          CountryFlagIcon(
                            countryCode: resolvedCode,
                            size: compact ? 22 : 26,
                          ),
                          SizedBox(width: compact ? 7 : 9),
                          Expanded(
                            child: Text(
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: SsrvpnUiTokens.textPrimary,
                                fontSize: compact ? 16 : 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        latencyText,
                        style: TextStyle(
                          color: latencyColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: compact ? 8 : 12),
                Icon(
                  Icons.chevron_right_rounded,
                  color: SsrvpnUiTokens.textSecondary,
                  size: compact ? 24 : 28,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionDetails extends StatelessWidget {
  const _ConnectionDetails({
    required this.errorMessage,
    required this.connectionNotice,
    required this.publicIpv4,
    required this.publicIpError,
    required this.isRefreshingPublicIp,
    required this.onShowLogs,
    required this.onRefreshPublicIp,
  });

  final String? errorMessage;
  final String? connectionNotice;
  final String? publicIpv4;
  final String? publicIpError;
  final bool isRefreshingPublicIp;
  final VoidCallback onShowLogs;
  final VoidCallback onRefreshPublicIp;

  @override
  Widget build(BuildContext context) {
    if (errorMessage != null) {
      return TextButton.icon(
        onPressed: onShowLogs,
        icon: const Icon(Icons.error_outline_rounded, size: 18),
        label: Text(
          errorMessage!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        style: TextButton.styleFrom(foregroundColor: SsrvpnUiTokens.error),
      );
    }
    if (connectionNotice != null) {
      return TextButton.icon(
        onPressed: onShowLogs,
        icon: const Icon(Icons.sync_rounded, size: 18),
        label: Text(
          connectionNotice!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        style: TextButton.styleFrom(foregroundColor: SsrvpnUiTokens.warning),
      );
    }
    final label = isRefreshingPublicIp
        ? '正在获取公网 IPv4…'
        : publicIpv4 != null
            ? '公网 IPv4  $publicIpv4'
            : publicIpError ?? '获取公网 IPv4';
    return TextButton.icon(
      onPressed: isRefreshingPublicIp ? null : onRefreshPublicIp,
      icon: isRefreshingPublicIp
          ? const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.public_rounded, size: 17),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: SsrvpnUiTokens.textSecondary,
      ),
    );
  }
}
