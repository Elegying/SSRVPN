import '../models/network_verification.dart';
import 'ssrvpn_home_network_controls.dart';
import 'ssrvpn_pixel_surface.dart';
import 'ssrvpn_cloud_art.dart';
import '../models/app_settings.dart';
import 'ssrvpn_themed_power_button.dart';
import 'ssrvpn_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'ssrvpn_home_text.dart';
import 'ssrvpn_home_shell.dart';
import 'ssrvpn_connection_halo.dart';

import '../models/proxy_node.dart';
import '../utils/node_country_policy.dart';
import '../utils/node_display_policy.dart';
import 'country_flag_icon.dart';
import 'ssrvpn_app_surface.dart';

part 'ssrvpn_home_overview_header.dart';
part 'ssrvpn_power_button.dart';
part 'ssrvpn_home_centered_layout.dart';
part 'ssrvpn_themed_home.dart';

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
    this.onDiagnostic,
    this.errorMessage,
    this.connectionNotice,
    this.networkVerification,
    this.connectionProgress,
    this.isAutoRecovering = false,
    this.publicIpv4,
    this.publicIpError,
    this.isRefreshingPublicIp = false,
    this.bottomContent,
    this.hasAccountStatistics = false,
    this.enableTun = false,
    this.showModeControls = true,
    this.onEnableTunChanged,
  });

  final ValueChanged<String>? onDiagnostic;
  final bool isConnected;
  final bool isConnecting;
  final ProxyNode? selectedNode;
  final int? selectedLatency;
  final String? selectedCountryCode;
  final String? errorMessage;
  final String? connectionNotice;
  final NetworkVerification? networkVerification;
  final String? connectionProgress;

  /// Keeps connection controls busy while recovery rebuilds the connection.
  final bool isAutoRecovering;
  final String? publicIpv4;
  final String? publicIpError;
  final bool isRefreshingPublicIp;
  final Widget? bottomContent;
  final bool hasAccountStatistics;
  final bool enableTun, showModeControls;
  final ValueChanged<bool>? onEnableTunChanged;
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
  @override
  void initState() {
    super.initState();
    _logChanges(null);
  }

  @override
  void didUpdateWidget(SsrvpnHomeOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    _logChanges(oldWidget);
  }

  void _logChanges(SsrvpnHomeOverview? previous) {
    final messages = <String>{};
    void changed(String? current, String? old) {
      if (current != null && current.isNotEmpty && current != old) {
        messages.add(current);
      }
    }

    changed(widget.errorMessage, previous?.errorMessage);
    changed(widget.connectionNotice, previous?.connectionNotice);
    if (widget.isConnecting || widget.isAutoRecovering) {
      changed(widget.connectionProgress, previous?.connectionProgress);
    }
    for (final message in messages) {
      widget.onDiagnostic?.call(message);
    }
  }

  // Preserve both samplers when responsive rows reparent the statistics subtree.
  final _statisticsKey = GlobalKey();
  @override
  Widget build(BuildContext context) => SizedBox.expand(
      key: const Key('ssrvpn-home-canvas'), child: _homeCanvas());

  Widget _publicIpCard() => SsrvpnPublicIpCard(
      value: widget.publicIpv4,
      error: widget.publicIpError,
      refreshing: widget.isRefreshingPublicIp,
      busy: widget.isConnecting || widget.isAutoRecovering,
      onRefresh: widget.onRefreshPublicIp);
  Widget _modeControls() => SsrvpnHomeModeControls(
      enableTun: widget.enableTun,
      busy: widget.isConnecting || widget.isAutoRecovering,
      onChanged: widget.onEnableTunChanged);

  Widget _homeCanvas() {
    if (!SsrvpnTheme.of(context).isDefault) return _themedHome();
    final viewport = MediaQuery.of(context);
    // Include the navigation in the home midpoint, exclude system/window insets.
    final centerY = ((viewport.size.height - viewport.padding.vertical) / 2 -
            SsrvpnHomeShell.bodyTopOf(context)) -
        4;
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < SsrvpnUiTokens.compactBreakpoint;
        const padding = 18.0;
        final powerSize = compact ? 154.0 : 170.0;
        final status =
            _ConnectionStatusPill(label: _statusText, color: _statusColor);
        Widget node() => ConstrainedBox(
            constraints:
                BoxConstraints(maxWidth: SsrvpnUiTokens.currentNodeMaxWidth),
            child: SsrvpnCurrentNodeCard(
                node: widget.selectedNode,
                latency: widget.selectedLatency,
                countryCode: widget.selectedCountryCode,
                compact: true,
                onTap: widget.onOpenNodes));
        return Padding(
            padding: EdgeInsets.fromLTRB(padding, 4, padding, 4),
            child: Center(
                child: ConstrainedBox(
                    key: const Key('ssrvpn-home-content'),
                    constraints: const BoxConstraints(
                        maxWidth: SsrvpnUiTokens.pageMaxWidth),
                    child: _centeredHome(
                        centerY: centerY,
                        powerSize: powerSize,
                        compact: compact,
                        status: status,
                        node: node()))));
      }),
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
    final latencyText = NodeDisplayPolicy.latencyText(latency);
    final Color latencyColor;
    if (latency == null || NodeDisplayPolicy.isLocalProbeBlocked(latency)) {
      latencyColor = SsrvpnUiTokens.of(context).textSecondary;
    } else if (latencyTimedOut || latency! >= 350) {
      latencyColor = SsrvpnUiTokens.of(context).error;
    } else if (latency! < 180) {
      latencyColor = SsrvpnUiTokens.of(context).success;
    } else {
      latencyColor = SsrvpnUiTokens.of(context).warning;
    }
    final radius = compact ? 22.0 : 26.0;
    final iconSize = compact ? 48.0 : 58.0;
    return Semantics(
      button: true,
      label: node == null ? '选择服务器' : '当前节点 $displayName，打开服务器选择',
      child: Material(
        key: Key('ssrvpn-current-node-card'),
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
                    color: SsrvpnUiTokens.of(context).primary,
                    borderRadius: BorderRadius.circular(compact ? 15 : 17),
                    boxShadow: ssrvpnUsesLowEffects(context)
                        ? []
                        : [
                            BoxShadow(
                              color: SsrvpnUiTokens.of(context)
                                  .primary
                                  .withValues(alpha: 0.28),
                              blurRadius: 18,
                              offset: Offset(0, 8),
                            ),
                          ],
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    color: SsrvpnUiTokens.of(context).onPrimary,
                    size: compact ? 24 : 26,
                  ),
                ),
                SizedBox(width: compact ? 12 : 18),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                          child: SsrvpnHomeText(
                        '当前节点',
                        maxFontSize: 12,
                        style: TextStyle(
                          color: SsrvpnUiTokens.of(context).textSecondary,
                          fontSize: compact ? 12 : 13,
                        ),
                      )),
                      SizedBox(height: 4),
                      Flexible(
                          flex: 2,
                          child: Row(
                            children: [
                              CountryFlagIcon(
                                countryCode: resolvedCode,
                                size: compact ? 22 : 26,
                              ),
                              SizedBox(width: compact ? 7 : 9),
                              Expanded(
                                child: SsrvpnHomeText(
                                  visibleName,
                                  maxFontSize: compact ? 18 : 20,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color:
                                        SsrvpnUiTokens.of(context).textPrimary,
                                    fontSize: compact ? 18 : 20,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          )),
                      SizedBox(height: 3),
                      Flexible(
                          child: SsrvpnHomeText(
                        latencyText,
                        maxFontSize: 13,
                        style: TextStyle(
                          color: latencyColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      )),
                    ],
                  ),
                ),
                SizedBox(width: compact ? 8 : 12),
                Icon(
                  Icons.chevron_right_rounded,
                  color: SsrvpnUiTokens.of(context).textSecondary,
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
