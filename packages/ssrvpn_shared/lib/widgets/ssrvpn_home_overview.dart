import 'package:flutter/material.dart';
import 'ssrvpn_home_text.dart';

import '../models/proxy_node.dart';
import '../utils/node_country_policy.dart';
import '../utils/node_display_policy.dart';
import 'country_flag_icon.dart';
import 'ssrvpn_app_surface.dart';

part 'ssrvpn_home_overview_header.dart';

class SsrvpnHomeOverview extends StatefulWidget {
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
    this.bottomContent,
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
  final Widget? bottomContent;
  final VoidCallback onToggleConnection;
  final VoidCallback onOpenNodes;
  final VoidCallback onShowAbout;
  final VoidCallback onShowTutorial;
  final VoidCallback onShowLogs;
  final VoidCallback onRefreshPublicIp;

  @override
  State<SsrvpnHomeOverview> createState() => _HomeOverviewState();
}

class _HomeOverviewState extends State<SsrvpnHomeOverview> {
  // Preserve both samplers when responsive rows reparent the statistics subtree.
  final _statisticsKey = GlobalKey();
  String get _statusText {
    if (widget.isConnecting) return widget.isConnected ? '正在断开' : '正在连接';
    if (widget.errorMessage != null) return '连接异常';
    if (widget.isConnected && widget.connectionNotice != null) return '网络待确认';
    if (widget.isConnected) return '已连接';
    return '未连接';
  }

  Color get _statusColor {
    if (widget.isConnecting) return SsrvpnUiTokens.warning;
    if (widget.errorMessage != null) return SsrvpnUiTokens.error;
    if (widget.isConnected && widget.connectionNotice != null) {
      return SsrvpnUiTokens.warning;
    }
    if (widget.isConnected) return SsrvpnUiTokens.success;
    return SsrvpnUiTokens.textSecondary;
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        bottom: false,
        child: LayoutBuilder(builder: (context, constraints) {
          final compact =
              constraints.maxWidth < SsrvpnUiTokens.compactBreakpoint;
          final short = constraints.maxHeight < 610;
          final wide =
              constraints.maxWidth >= 560 && constraints.maxHeight < 450;
          final padding = compact ? 18.0 : 20.0;
          final powerSize = short ? 124.0 : (compact ? 154.0 : 170.0);
          final detailsVisible = widget.isConnected ||
              widget.errorMessage != null ||
              widget.connectionNotice != null;
          final minimal = constraints.maxHeight < (detailsVisible ? 490 : 430);
          final gap = minimal ? 4.0 : 12.0;
          final status =
              _ConnectionStatusPill(label: _statusText, color: _statusColor);
          final details = _ConnectionDetails(
              errorMessage: widget.errorMessage,
              connectionNotice: widget.connectionNotice,
              publicIpv4: widget.publicIpv4,
              publicIpError: widget.publicIpError,
              isRefreshingPublicIp: widget.isRefreshingPublicIp,
              onShowLogs: widget.onShowLogs,
              onRefreshPublicIp: widget.onRefreshPublicIp);
          final power = SsrvpnPowerButton(
              size: powerSize,
              isConnected: widget.isConnected,
              isConnecting: widget.isConnecting,
              hasConnectionError: widget.errorMessage != null,
              onTap: widget.onToggleConnection);
          Widget node() => ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: compact ? 300 : SsrvpnUiTokens.currentNodeMaxWidth),
              child: SsrvpnCurrentNodeCard(
                  node: widget.selectedNode,
                  latency: widget.selectedLatency,
                  countryCode: widget.selectedCountryCode,
                  compact: true,
                  onTap: widget.onOpenNodes));
          Widget statistics({bool fill = true}) {
            if (widget.bottomContent == null) return const SizedBox();
            final child = Align(
                alignment: Alignment.bottomCenter,
                child: KeyedSubtree(
                    key: _statisticsKey, child: widget.bottomContent!));
            return fill
                ? Expanded(child: child)
                : ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: (constraints.maxHeight - powerSize - 36)
                            .clamp(0, double.infinity)),
                    child: child);
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(padding, 4, padding, 4),
            child: Center(
                child: ConstrainedBox(
                    key: const Key('ssrvpn-home-content'),
                    constraints: BoxConstraints(
                        maxWidth: wide ? 920 : SsrvpnUiTokens.pageMaxWidth),
                    child: Column(children: [
                      if (!wide) ...[
                        SizedBox(
                            height: 48,
                            child: _HomeHeader(
                                compact: compact,
                                onShowAbout: widget.onShowAbout,
                                onShowTutorial: widget.onShowTutorial)),
                        SizedBox(height: gap),
                      ],
                      if (wide)
                        Expanded(
                            child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                              Column(mainAxisSize: MainAxisSize.min, children: [
                                status,
                                const SizedBox(height: 8),
                                power
                              ]),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: Column(children: [
                                SizedBox(
                                    height: 48,
                                    child: _HomeHeader(
                                        compact: compact,
                                        onShowAbout: widget.onShowAbout,
                                        onShowTutorial: widget.onShowTutorial)),
                                SizedBox(height: gap),
                                Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(child: node()),
                                      const SizedBox(width: 8),
                                      Expanded(
                                          child: ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                  maxHeight: 100),
                                              child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    if (detailsVisible)
                                                      Flexible(child: details)
                                                  ]))),
                                    ]),
                              ])),
                            ])),
                      if (wide)
                        statistics(fill: false)
                      else ...[
                        if (minimal)
                          Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      status,
                                      const SizedBox(height: 8),
                                      power
                                    ]),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                      if (constraints.maxWidth >= 360) node(),
                                      if (detailsVisible)
                                        ConstrainedBox(
                                            constraints: const BoxConstraints(
                                                maxHeight: 100),
                                            child: details),
                                    ])),
                              ])
                        else ...[
                          status,
                          const SizedBox(height: 10),
                          power,
                          SizedBox(height: gap),
                          node(),
                          if (detailsVisible)
                            ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxHeight: 60),
                                child: details),
                        ],
                        if (minimal && constraints.maxWidth < 360) node(),
                        SizedBox(height: gap),
                        statistics(),
                      ],
                    ]))),
          );
        }),
      );
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
    final visibleName = compactNodeDisplayName(displayName);
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
                      SsrvpnHomeText(
                        '当前节点',
                        maxFontSize: 12,
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
                            child: Tooltip(
                              message: displayName,
                              child: SsrvpnHomeText(
                                visibleName,
                                maxFontSize: compact ? 16 : 18,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: SsrvpnUiTokens.textPrimary,
                                  fontSize: compact ? 16 : 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      SsrvpnHomeText(
                        latencyText,
                        maxFontSize: 12,
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
        label: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
                child: SsrvpnHomeText(errorMessage!,
                    maxLines: null, maxFontSize: 14)),
            const SizedBox(height: 4),
            const SsrvpnHomeText(
              '查看诊断与解决建议',
              maxLines: null,
              maxFontSize: 12,
              style: TextStyle(
                color: SsrvpnUiTokens.textSecondary,
                decoration: TextDecoration.underline,
              ),
            ),
          ],
        ),
        style: TextButton.styleFrom(foregroundColor: SsrvpnUiTokens.error),
      );
    }
    if (connectionNotice != null) {
      return TextButton.icon(
        onPressed: onShowLogs,
        icon: const Icon(Icons.sync_rounded, size: 18),
        label: SsrvpnHomeText(
          connectionNotice!,
          maxLines: null,
          maxFontSize: 14,
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
      label: SsrvpnHomeText(label, maxLines: null, maxFontSize: 14),
      style: TextButton.styleFrom(
        foregroundColor: SsrvpnUiTokens.textSecondary,
      ),
    );
  }
}
