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
                  child: Tooltip(
                    message: name,
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
      showHeading: false,
    );
    return RepaintBoundary(
      key: const Key('ssrvpn-proxy-mode-panel'),
      child: SsrvpnSurfaceCard(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
        radius: 14,
        color: const Color(0xEE2B2D48),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tunControl = enableTun == null || onEnableTunChanged == null
                ? null
                : _TunHeaderControl(
                    value: enableTun!,
                    label: tunLabel ?? 'TUN',
                    enabled: !busy,
                    onChanged: onEnableTunChanged!,
                  );
            final compactHeader = constraints.maxWidth < 340 ||
                MediaQuery.textScalerOf(context).scale(13) > 18;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (compactHeader) ...[
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      const _ModePanelTitle(),
                      if (tunControl != null) tunControl,
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '国内直连，国外走代理',
                    style: TextStyle(
                      color: SsrvpnUiTokens.primaryBlue,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ] else
                  Row(
                    children: [
                      const _ModePanelTitle(),
                      const SizedBox(width: 18),
                      const Expanded(
                        child: Text(
                          '国内直连，国外走代理',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: SsrvpnUiTokens.primaryBlue,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (tunControl != null) ...[
                        const SizedBox(width: 10),
                        tunControl,
                      ],
                    ],
                  ),
                const SizedBox(height: 12),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: constraints.maxWidth >= 340 ? 30 : 0,
                  ),
                  child: proxyChoices,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ModePanelTitle extends StatelessWidget {
  const _ModePanelTitle();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.alt_route_rounded,
          color: SsrvpnUiTokens.textPrimary,
          size: 20,
        ),
        SizedBox(width: 10),
        Text(
          '代理模式',
          style: TextStyle(
            color: SsrvpnUiTokens.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _TunHeaderControl extends StatelessWidget {
  const _TunHeaderControl({
    required this.value,
    required this.label,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final activate = enabled ? () => onChanged(!value) : null;
    return Semantics(
      container: true,
      label: label,
      toggled: value,
      enabled: enabled,
      onTap: activate,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: const Key('ssrvpn-tun-toggle'),
            borderRadius: BorderRadius.circular(16),
            onTap: activate,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.settings_rounded,
                    color: SsrvpnUiTokens.textSecondary,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label.startsWith('TUN') ? 'TUN' : label,
                    style: const TextStyle(
                      color: SsrvpnUiTokens.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  IgnorePointer(
                    child: SizedBox(
                      width: 52,
                      height: 32,
                      child: FittedBox(
                        fit: BoxFit.fill,
                        child: Switch(
                          value: value,
                          onChanged: enabled ? onChanged : null,
                          activeThumbColor: Colors.white,
                          activeTrackColor: SsrvpnUiTokens.primary,
                          inactiveThumbColor: Colors.white,
                          inactiveTrackColor: const Color(0xFF53566F),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
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
    this.showHeading = true,
  });

  final String title;
  final String description;
  final T value;
  final List<_ModeChoice<T>> choices;
  final bool enabled;
  final ValueChanged<T> onChanged;
  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeading) ...[
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
        ],
        Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: const Color(0xFF3A3C58),
            borderRadius: BorderRadius.circular(13),
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
                    focusRadius: 9,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      decoration: BoxDecoration(
                        color: selected
                            ? SsrvpnUiTokens.primary.withValues(alpha: 0.24)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                        border: selected
                            ? Border.all(
                                color: SsrvpnUiTokens.primary.withValues(
                                  alpha: 0.75,
                                ),
                              )
                            : null,
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                        child: InkWell(
                          canRequestFocus: false,
                          excludeFromSemantics: true,
                          borderRadius: BorderRadius.circular(9),
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
                                        ? SsrvpnUiTokens.primary
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
                                            ? SsrvpnUiTokens.primary
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
            child: Tooltip(
              message: group,
              child: Text(
                group,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ],
      onChanged: onChanged,
    );
  }
}
