part of 'ssrvpn_node_selection_page.dart';

class _NodeSelectionHeader extends StatelessWidget {
  const _NodeSelectionHeader({
    required this.selectedNode,
    required this.countryCode,
    required this.busy,
    required this.onClose,
    required this.onRefresh,
    required this.onTestAll,
  });

  final ProxyNode? selectedNode;
  final String countryCode;
  final bool busy;
  final VoidCallback onClose;
  final VoidCallback onRefresh;
  final VoidCallback onTestAll;

  @override
  Widget build(BuildContext context) {
    final name = selectedNode == null
        ? '选择服务器'
        : nodeDisplayNameWithoutLeadingFlag(selectedNode!.name);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Row(
        children: [
          IconButton(
            key: const Key('ssrvpn-node-close'),
            tooltip: '关闭服务器选择',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 30),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CountryFlagIcon(countryCode: countryCode, size: 28),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: SsrvpnUiTokens.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '刷新节点',
            onPressed: busy ? null : onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 28),
          ),
          IconButton(
            tooltip: '测试全部节点延迟',
            onPressed: busy ? null : onTestAll,
            icon: const Icon(Icons.bolt_rounded, size: 28),
          ),
        ],
      ),
    );
  }
}

class _ModePanel extends StatelessWidget {
  const _ModePanel({
    required this.proxyMode,
    required this.enableTun,
    required this.tunLabel,
    required this.busy,
    required this.onProxyModeChanged,
    required this.onEnableTunChanged,
  });

  final ProxyMode proxyMode;
  final bool? enableTun;
  final String? tunLabel;
  final bool busy;
  final ValueChanged<ProxyMode> onProxyModeChanged;
  final ValueChanged<bool>? onEnableTunChanged;

  @override
  Widget build(BuildContext context) {
    final proxyChoices = _ModeSection<ProxyMode>(
      title: '代理模式',
      description: '国内直连，国外走代理',
      value: proxyMode,
      choices: const [
        _ModeChoice(ProxyMode.rule, '智能', Icons.auto_awesome_rounded),
        _ModeChoice(ProxyMode.global, '全局', Icons.public_rounded),
      ],
      enabled: !busy,
      onChanged: onProxyModeChanged,
    );
    final connectionChoices = enableTun == null || onEnableTunChanged == null
        ? null
        : _ModeSection<bool>(
            title: '代理方式',
            description: '按当前设备选择接管范围',
            value: enableTun!,
            choices: [
              const _ModeChoice(false, '系统代理', Icons.language_rounded),
              _ModeChoice(
                true,
                tunLabel ?? 'TUN 模式',
                Icons.wifi_tethering_rounded,
              ),
            ],
            enabled: !busy,
            onChanged: onEnableTunChanged!,
          );
    return SsrvpnSurfaceCard(
      padding: const EdgeInsets.all(16),
      radius: 22,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (connectionChoices == null) return proxyChoices;
          if (constraints.maxWidth < 620) {
            return Column(
              children: [
                proxyChoices,
                const SizedBox(height: 14),
                connectionChoices,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: proxyChoices),
              const SizedBox(width: 16),
              Expanded(child: connectionChoices),
            ],
          );
        },
      ),
    );
  }
}

class _ModeChoice<T> {
  const _ModeChoice(this.value, this.label, this.icon);

  final T value;
  final String label;
  final IconData icon;
}

class _ModeSection<T> extends StatelessWidget {
  const _ModeSection({
    required this.title,
    required this.description,
    required this.value,
    required this.choices,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final String description;
  final T value;
  final List<_ModeChoice<T>> choices;
  final bool enabled;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                color: SsrvpnUiTokens.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                description,
                textAlign: TextAlign.end,
                style: const TextStyle(
                  color: SsrvpnUiTokens.textSecondary,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: const Color(0xFF34364F),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: choices.map((choice) {
              final selected = choice.value == value;
              final VoidCallback? activate = enabled
                  ? () {
                      if (!selected) onChanged(choice.value);
                    }
                  : null;
              return Expanded(
                child: Semantics(
                  container: true,
                  label: choice.label,
                  button: true,
                  enabled: enabled,
                  selected: selected,
                  inMutuallyExclusiveGroup: true,
                  onTap: activate,
                  child: _KeyboardActivate(
                    enabled: enabled,
                    onActivate: activate ?? () {},
                    debugLabel: 'mode:${choice.label}',
                    focusRadius: 12,
                    child: Material(
                      color: selected
                          ? SsrvpnUiTokens.primary.withValues(alpha: 0.28)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        canRequestFocus: false,
                        excludeFromSemantics: true,
                        borderRadius: BorderRadius.circular(12),
                        onTap: activate,
                        child: ExcludeSemantics(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 11,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  choice.icon,
                                  size: 17,
                                  color: selected
                                      ? SsrvpnUiTokens.textPrimary
                                      : SsrvpnUiTokens.textSecondary,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    choice.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: selected
                                          ? SsrvpnUiTokens.textPrimary
                                          : SsrvpnUiTokens.textSecondary,
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                      fontSize: 13,
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
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _UtilityActions extends StatelessWidget {
  const _UtilityActions({
    required this.forceProxyEnabled,
    this.onShowForceProxySites,
    this.onShowLogs,
  });

  final bool forceProxyEnabled;
  final VoidCallback? onShowForceProxySites;
  final VoidCallback? onShowLogs;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 0,
      children: [
        if (onShowForceProxySites != null)
          TextButton.icon(
            onPressed: forceProxyEnabled ? onShowForceProxySites : null,
            icon: const Icon(Icons.add_link_rounded, size: 17),
            label: const Text('强制代理网站'),
          ),
        if (onShowLogs != null)
          TextButton.icon(
            onPressed: onShowLogs,
            icon: const Icon(Icons.receipt_long_rounded, size: 17),
            label: const Text('运行日志'),
          ),
      ],
    );
  }
}

class _SubscriptionFilter extends StatelessWidget {
  const _SubscriptionFilter({
    required this.groups,
    required this.value,
    required this.onChanged,
  });

  final List<String> groups;
  final String value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: ValueKey('ssrvpn-subscription-filter-$value'),
      initialValue: value,
      isExpanded: true,
      dropdownColor: SsrvpnUiTokens.surfaceStrong,
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
      decoration: InputDecoration(
        filled: true,
        fillColor: SsrvpnUiTokens.surface.withValues(alpha: 0.9),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: SsrvpnUiTokens.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: SsrvpnUiTokens.border),
        ),
      ),
      items: [
        const DropdownMenuItem(
          value: '*',
          child: Text('全部订阅', overflow: TextOverflow.ellipsis),
        ),
        ...groups.map(
          (group) => DropdownMenuItem(
            value: group,
            child: Text(
              group,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
      onChanged: onChanged,
    );
  }
}
