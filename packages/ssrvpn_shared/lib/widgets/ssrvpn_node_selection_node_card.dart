part of 'ssrvpn_node_selection_page.dart';

class _NodeSelectionCard extends StatelessWidget {
  const _NodeSelectionCard({
    required this.node,
    required this.countryCode,
    required this.latency,
    required this.selected,
    required this.testing,
    required this.selectionBusy,
    required this.editBusy,
    required this.testingBusy,
    required this.onSelect,
    required this.onTest,
    this.onSecondaryTapDown,
    this.onLongPress,
    this.pinned = false,
  });

  final bool pinned;
  final ProxyNode node;
  final String countryCode;
  final int? latency;
  final bool selected;
  final bool testing;
  final bool selectionBusy;
  final bool editBusy;
  final bool testingBusy;
  final VoidCallback onSelect;
  final VoidCallback onTest;
  final GestureTapDownCallback? onSecondaryTapDown;
  final VoidCallback? onLongPress;

  Color _latencyColor(BuildContext context) {
    if (latency == null || NodeDisplayPolicy.isLocalProbeBlocked(latency)) {
      return SsrvpnUiTokens.of(context).textSecondary;
    }
    if (latency! <= 0 || latency! >= 65535) {
      return SsrvpnUiTokens.of(context).error;
    }
    if (latency! < 180) return SsrvpnUiTokens.of(context).success;
    if (latency! < 350) return SsrvpnUiTokens.of(context).warning;
    return SsrvpnUiTokens.of(context).error;
  }

  String get _latencyText => NodeDisplayPolicy.latencyText(latency);

  @override
  Widget build(BuildContext context) {
    final displayName = nodeDisplayNameWithoutLeadingFlag(node.name);
    final visibleName = compactNodeDisplayName(displayName);
    final compact =
        MediaQuery.sizeOf(context).width < SsrvpnUiTokens.compactBreakpoint;
    final radius = compact ? 17.0 : 20.0;
    return Padding(
      padding: SsrvpnTheme.of(context).isSoft
          ? const EdgeInsets.fromLTRB(32, 8, 32, 16)
          : EdgeInsets.only(bottom: compact ? 7 : 10),
      child: Material(
        key: ValueKey('ssrvpn-node-card-${node.name}'),
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        child: SsrvpnLiquidSurface(
          radius: radius,
          dense: true,
          tint: selected ? SsrvpnUiTokens.of(context).primary : null,
          borderColor: selected
              ? SsrvpnUiTokens.of(context).primary.withValues(alpha: .8)
              : null,
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  container: true,
                  button: true,
                  enabled: !selectionBusy,
                  selected: selected,
                  inMutuallyExclusiveGroup: true,
                  label: '选择服务器 $displayName${pinned ? '，已置顶' : ''}',
                  onTap: selectionBusy ? null : onSelect,
                  onLongPress: editBusy ? null : onLongPress,
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
                            editBusy ? null : onSecondaryTapDown,
                        onLongPress: editBusy ? null : onLongPress,
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
                                if (pinned)
                                  Padding(
                                      padding: EdgeInsets.only(right: 4),
                                      child: Icon(Icons.push_pin, size: 16)),
                                CountryFlagIcon(
                                  countryCode: countryCode,
                                  size: compact ? 34 : 42,
                                ),
                                SizedBox(width: compact ? 12 : 16),
                                Expanded(
                                  child: Tooltip(
                                    message: displayName,
                                    // Mouse hover remains available, while
                                    // touch long-press belongs exclusively to
                                    // the surrounding node edit action.
                                    triggerMode: TooltipTriggerMode.manual,
                                    child: Text(
                                      visibleName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: selected
                                            ? SsrvpnUiTokens.of(context).primary
                                            : SsrvpnUiTokens.of(context)
                                                .textPrimary,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
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
                  foregroundColor: _latencyColor(context),
                  minimumSize: Size(compact ? 64 : 70, compact ? 44 : 48),
                ),
                child: Semantics(
                  label: '测试 $displayName 延迟',
                  value: testing ? '测试中' : _latencyText,
                  excludeSemantics: true,
                  child: testing
                      ? SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _latencyColor(context),
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
                    ? Icon(
                        Icons.check_circle_rounded,
                        color: SsrvpnUiTokens.of(context).primary,
                        size: 22,
                      )
                    : null,
              ),
              SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}

class _NodeEmptyState extends StatelessWidget {
  const _NodeEmptyState({this.filtered = false});
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 48,
            color: SsrvpnUiTokens.of(context).textTertiary,
          ),
          SizedBox(height: 12),
          Text(
            filtered ? '没有匹配节点，请修改或清除搜索' : '暂无可用节点',
            style: TextStyle(color: SsrvpnUiTokens.of(context).textSecondary),
          ),
        ],
      ),
    );
  }
}

// Keep the soft shadow inside the Android swipe clip and scroll viewport.
EdgeInsets _nodeListPadding(BuildContext context) =>
    SsrvpnTheme.of(context).isSoft
        ? const EdgeInsets.only(top: 8)
        : const EdgeInsets.fromLTRB(18, 8, 18, 0);
Widget _nodeListControls(BuildContext context, Widget child) =>
    SsrvpnTheme.of(context).isSoft
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18), child: child)
        : child;
