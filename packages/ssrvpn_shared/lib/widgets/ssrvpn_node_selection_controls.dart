part of 'ssrvpn_node_selection_page.dart';

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
