part of 'ssrvpn_node_selection_page.dart';

class _ModePanel extends StatelessWidget {
  const _ModePanel({
    required this.proxyMode,
    required this.busy,
    required this.onProxyModeChanged,
  });

  final ProxyMode proxyMode;
  final bool busy;
  final ValueChanged<ProxyMode> onProxyModeChanged;

  @override
  Widget build(BuildContext context) {
    final modeDescription =
        proxyMode == ProxyMode.global ? '所有流量都走代理' : '国内服务直接连接，海外及未知流量走代理';
    final proxyChoices = _ModeSection<ProxyMode>(
      title: '代理模式',
      description: modeDescription,
      value: proxyMode,
      choices: [
        _ModeChoice(ProxyMode.rule, '智能', Icons.auto_awesome_rounded),
        _ModeChoice(ProxyMode.global, '全局', Icons.public_rounded),
      ],
      enabled: !busy,
      onChanged: onProxyModeChanged,
      showHeading: false,
    );
    return RepaintBoundary(
      key: Key('ssrvpn-proxy-mode-panel'),
      child: Stack(children: [
        Positioned.fill(
          child: SsrvpnLiquidSurface(
              radius: 14, dense: true, child: SizedBox.expand()),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(18, 12, 18, 14),
          child: LayoutBuilder(
            builder: (context, constraints) {
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
                      ],
                    ),
                    SizedBox(height: 6),
                    Text(
                      modeDescription,
                      style: TextStyle(
                        color: SsrvpnUiTokens.of(context).textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ] else
                    Row(
                      children: [
                        const _ModePanelTitle(),
                        SizedBox(width: 18),
                        Expanded(
                          child: Text(
                            modeDescription,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: SsrvpnUiTokens.of(context).textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  SizedBox(height: 12),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.alt_route_rounded,
          color: SsrvpnUiTokens.of(context).textPrimary,
          size: 20,
        ),
        SizedBox(width: 10),
        Text(
          '代理模式',
          style: TextStyle(
            color: SsrvpnUiTokens.of(context).textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
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
    final soft =
        SsrvpnTheme.of(context).isSoft && !MediaQuery.highContrastOf(context);
    final height = 27.0 + MediaQuery.textScalerOf(context).scale(14) * 1.5;
    return SizedBox(
        height: height,
        child: Stack(children: [
          ExcludeFocus(
              child: ExcludeSemantics(
                  child: IgnorePointer(
            child: Stack(fit: StackFit.expand, children: [
              if (!soft)
                SsrvpnLiquidSurface(
                    radius: 13,
                    dense: true,
                    tint: SsrvpnTheme.of(context).surfaceStrong,
                    child: SizedBox.expand()),
              AnimatedAlign(
                alignment: value == choices.first.value
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: FractionallySizedBox(
                    widthFactor: 1 / choices.length,
                    heightFactor: 1,
                    child: soft
                        ? SsrvpnSoftInset(
                            key: ValueKey('soft-mode-$value'),
                            radius: 10,
                            child: const SizedBox.expand())
                        : SsrvpnLiquidSurface(
                            radius: 10,
                            dense: true,
                            tint: SsrvpnTheme.of(context).primary,
                            child: SizedBox.expand())),
              ),
              Row(children: [
                for (final choice in choices)
                  Expanded(
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                        Icon(choice.icon,
                            size: 17,
                            color: choice.value == value
                                ? SsrvpnUiTokens.of(context).textPrimary
                                : SsrvpnUiTokens.of(context).textSecondary),
                        Text(choice.label,
                            style: TextStyle(
                                fontSize: 14,
                                height: 1.5,
                                fontWeight: choice.value == value
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                color: choice.value == value
                                    ? SsrvpnUiTokens.of(context).textPrimary
                                    : SsrvpnUiTokens.of(context)
                                        .textSecondary)),
                      ])),
              ]),
            ]),
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
                        child: SizedBox.expand(),
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
