part of 'ssrvpn_node_selection_page.dart';

class _NodeSelectionCard extends StatelessWidget {
  const _NodeSelectionCard({
    required this.node,
    required this.countryCode,
    required this.latency,
    required this.selected,
    required this.testing,
    required this.selectionBusy,
    required this.testingBusy,
    required this.onSelect,
    required this.onTest,
    this.onSecondaryTapDown,
    this.onLongPress,
  });

  final ProxyNode node;
  final String countryCode;
  final int? latency;
  final bool selected;
  final bool testing;
  final bool selectionBusy;
  final bool testingBusy;
  final VoidCallback onSelect;
  final VoidCallback onTest;
  final GestureTapDownCallback? onSecondaryTapDown;
  final VoidCallback? onLongPress;

  Color get _latencyColor {
    if (latency == null) return SsrvpnUiTokens.textSecondary;
    if (latency! <= 0 || latency! >= 65535) {
      return SsrvpnUiTokens.error;
    }
    if (latency! < 180) return SsrvpnUiTokens.success;
    if (latency! < 350) return SsrvpnUiTokens.warning;
    return SsrvpnUiTokens.error;
  }

  String get _latencyText {
    if (latency == null) return '--';
    if (latency! <= 0 || latency! >= 65535) return '超时';
    return '${latency}ms';
  }

  @override
  Widget build(BuildContext context) {
    final displayName = nodeDisplayNameWithoutLeadingFlag(node.name);
    final compact =
        MediaQuery.sizeOf(context).width < SsrvpnUiTokens.compactBreakpoint;
    final radius = compact ? 17.0 : 20.0;
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 7 : 10),
      child: Material(
        key: ValueKey('ssrvpn-node-card-${node.name}'),
        color: selected
            ? SsrvpnUiTokens.surfaceStrong
            : SsrvpnUiTokens.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: selected
                  ? SsrvpnUiTokens.primary.withValues(alpha: 0.58)
                  : SsrvpnUiTokens.border,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  container: true,
                  button: true,
                  enabled: !selectionBusy,
                  selected: selected,
                  inMutuallyExclusiveGroup: true,
                  label: '选择服务器 $displayName',
                  onTap: selectionBusy ? null : onSelect,
                  onLongPress: selectionBusy ? null : onLongPress,
                  child: _KeyboardActivate(
                    enabled: !selectionBusy,
                    onActivate: onSelect,
                    debugLabel: 'node:$displayName',
                    focusRadius: radius,
                    child: Material(
                      key: ValueKey('ssrvpn-node-select-${node.name}'),
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(radius),
                      child: InkWell(
                        canRequestFocus: false,
                        excludeFromSemantics: true,
                        borderRadius: BorderRadius.circular(radius),
                        onTap: selectionBusy ? null : onSelect,
                        onSecondaryTapDown:
                            selectionBusy ? null : onSecondaryTapDown,
                        onLongPress: selectionBusy ? null : onLongPress,
                        child: ExcludeSemantics(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              compact ? 14 : 18,
                              compact ? 7 : 14,
                              compact ? 6 : 8,
                              compact ? 7 : 14,
                            ),
                            child: Row(
                              children: [
                                CountryFlagIcon(
                                  countryCode: countryCode,
                                  size: compact ? 34 : 42,
                                ),
                                SizedBox(width: compact ? 12 : 16),
                                Expanded(
                                  child: Text(
                                    displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: selected
                                          ? SsrvpnUiTokens.primary
                                          : SsrvpnUiTokens.textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: testingBusy ? null : onTest,
                style: TextButton.styleFrom(
                  foregroundColor: _latencyColor,
                  minimumSize: Size(compact ? 64 : 70, compact ? 44 : 48),
                ),
                child: Semantics(
                  button: true,
                  enabled: !testingBusy,
                  label: '测试 $displayName 延迟',
                  value: testing ? '测试中' : _latencyText,
                  excludeSemantics: true,
                  child: testing
                      ? SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _latencyColor,
                          ),
                        )
                      : Text(
                          _latencyText,
                          style: TextStyle(
                            fontSize: compact ? 14 : 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              SizedBox(
                width: compact ? 24 : 28,
                child: selected
                    ? const Icon(
                        Icons.check_circle_rounded,
                        color: SsrvpnUiTokens.primary,
                        size: 22,
                      )
                    : null,
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}

class _NodeEmptyState extends StatelessWidget {
  const _NodeEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 48,
            color: SsrvpnUiTokens.textTertiary,
          ),
          SizedBox(height: 12),
          Text(
            '暂无可用节点',
            style: TextStyle(color: SsrvpnUiTokens.textSecondary),
          ),
        ],
      ),
    );
  }
}
