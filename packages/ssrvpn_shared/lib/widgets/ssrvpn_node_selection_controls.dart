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
    final modeDescription =
        proxyMode == ProxyMode.global ? '所有流量都走代理' : '国内服务直接连接，海外及未知流量走代理';
    final proxyChoices = _ModeSection<ProxyMode>(
      title: '代理模式',
      description: modeDescription,
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
      child: Stack(children: [
        const Positioned.fill(
          child: SsrvpnLiquidSurface(
              radius: 14, dense: true, child: SizedBox.expand()),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
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
                    Text(
                      modeDescription,
                      style: TextStyle(
                        color: SsrvpnUiTokens.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ] else
                    Row(
                      children: [
                        const _ModePanelTitle(),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Text(
                            modeDescription,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: SsrvpnUiTokens.textSecondary,
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
      ]),
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
  const _ModeSection(
      {required this.title,
      required this.description,
      required this.value,
      required this.choices,
      required this.enabled,
      required this.onChanged,
      this.showHeading = true});
  final String title, description;
  final T value;
  final List<_ModeChoice<T>> choices;
  final bool enabled, showHeading;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final height =
        48.0 + (MediaQuery.textScalerOf(context).scale(14) - 14).clamp(0, 24);
    return SizedBox(
        height: height,
        child: Stack(children: [
          ExcludeFocus(
              child: ExcludeSemantics(
                  child: IgnorePointer(
            child: liquid.GlassSegmentedControl(
              selectedIndex:
                  choices.indexWhere((choice) => choice.value == value),
              onSegmentSelected: (_) {},
              height: height,
              borderRadius: 13,
              indicatorBorderRadius: 10,
              indicatorExpansion: EdgeInsets.zero,
              quality: ssrvpnGlassQuality(context),
              useOwnLayer: true,
              settings: SsrvpnLiquidSurface.settings,
              backgroundColor: const Color(0x183A3C58),
              indicatorSettings: SsrvpnLiquidSurface.settings.copyWith(
                  blur: 3, thickness: 36, glassColor: const Color(0x208A80FF)),
              indicatorColor: SsrvpnUiTokens.primary.withValues(alpha: .12),
              selectedTextStyle: const TextStyle(
                  color: SsrvpnUiTokens.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700),
              unselectedTextStyle: const TextStyle(
                  color: SsrvpnUiTokens.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600),
              segments: [
                for (final choice in choices)
                  liquid.GlassSegment(
                      label: choice.label, icon: Icon(choice.icon, size: 17))
              ],
            ),
          ))),
          // Keep our controlled confirmation, keyboard focus and single semantics
          // node per option. The glass layer only follows the accepted mode value.
          Positioned.fill(
              child: Row(children: [
            for (final choice in choices)
              Expanded(
                  child: Semantics(
                container: true,
                label: choice.label,
                button: true,
                enabled: enabled,
                selected: choice.value == value,
                inMutuallyExclusiveGroup: true,
                onTap: enabled
                    ? () {
                        if (choice.value != value) onChanged(choice.value);
                      }
                    : null,
                child: _KeyboardActivate(
                  enabled: enabled,
                  debugLabel: 'mode:${choice.label}',
                  focusRadius: 10,
                  onActivate: () {
                    if (enabled && choice.value != value) {
                      onChanged(choice.value);
                    }
                  },
                  child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        canRequestFocus: false,
                        excludeFromSemantics: true,
                        borderRadius: BorderRadius.circular(10),
                        onTap: enabled
                            ? () {
                                if (choice.value != value) {
                                  onChanged(choice.value);
                                }
                              }
                            : null,
                        child: const SizedBox.expand(),
                      )),
                ),
              )),
          ])),
        ]));
  }
}

extension _NodeSelectionModeActions on _SsrvpnNodeSelectionPageState {
  Future<void> _changeProxyMode(ProxyMode mode) => _runAction(() async {
        if (mode == widget.proxyModeOf()) return;
        if (mode == ProxyMode.global) {
          final confirmed = await showSsrvpnGlobalModeDialog(context);
          if (!confirmed || !mounted || widget.isConnectingOf()) return;
        }
        if (mode != widget.proxyModeOf()) {
          await widget.onProxyModeChanged(mode);
        }
      });
}
