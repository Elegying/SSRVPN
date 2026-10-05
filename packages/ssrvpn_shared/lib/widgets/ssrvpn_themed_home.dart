part of 'ssrvpn_home_overview.dart';

enum _ThemedPart {
  header,
  status,
  power,
  hint,
  node,
  ip,
  modes,
  details,
  statistics
}

extension _ThemedHome on _HomeOverviewState {
  Widget _themedHome() {
    final colors = SsrvpnTheme.of(context);
    final cloud = colors.variant == AppThemeVariant.cloud;
    final viewport = MediaQuery.of(context);
    final centerY = ((viewport.size.height - viewport.padding.vertical) / 2 -
        SsrvpnHomeShell.bodyTopOf(context));
    return ColoredBox(
        color: cloud ? colors.background : Colors.transparent,
        child: SafeArea(
            bottom: false,
            child: Padding(
                padding: EdgeInsets.symmetric(horizontal: cloud ? 0 : 18),
                child: LayoutBuilder(builder: (context, box) {
                  final width =
                      cloud ? box.maxWidth : box.maxWidth.clamp(0.0, 440.0);
                  final contentWidth =
                      cloud ? (width - 36).clamp(0.0, 440.0) : width;
                  final header = Padding(
                      padding: EdgeInsets.symmetric(horizontal: cloud ? 18 : 0),
                      child: SizedBox(
                          height: 48,
                          child: _HomeHeader(
                              compact: width < 400,
                              onShowAbout: widget.onShowAbout,
                              onShowTutorial: widget.onShowTutorial)));
                  final insetStatus = colors.isIllustrated &&
                      colors.variant != AppThemeVariant.pixel;
                  final status = insetStatus
                      ? const SizedBox.shrink()
                      : colors.variant == AppThemeVariant.pixel &&
                              !MediaQuery.highContrastOf(context)
                          ? SsrvpnPixelStatus(
                              label: _statusText, color: _statusColor)
                          : Semantics(
                              liveRegion: true,
                              child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 7),
                                  decoration: BoxDecoration(
                                      color:
                                          colors.surface.withValues(alpha: .86),
                                      borderRadius: BorderRadius.circular(28),
                                      border: Border.all(
                                          color: _statusColor.withValues(
                                              alpha: .2))),
                                  child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.circle,
                                            size: 12, color: _statusColor),
                                        const SizedBox(width: 9),
                                        Text(_statusText,
                                            style: TextStyle(
                                                fontSize: 17,
                                                fontWeight: FontWeight.w700,
                                                color: _statusColor))
                                      ])));
                  return Center(
                      child: SizedBox(
                          width: width,
                          child: CustomMultiChildLayout(
                              delegate: _ThemedHomeLayout(
                                  centerY: centerY,
                                  cloud: cloud,
                                  illustrated: colors.isIllustrated),
                              children: [
                                if (!cloud)
                                  LayoutId(
                                      id: _ThemedPart.header, child: header),
                                LayoutId(
                                    id: _ThemedPart.status,
                                    child: FittedBox(
                                        fit: BoxFit.scaleDown, child: status)),
                                LayoutId(
                                    id: _ThemedPart.power,
                                    child: cloud
                                        ? SsrvpnCloudHero(
                                            header: header,
                                            connecting: widget.isConnecting,
                                            connected: widget.isConnected,
                                            onTap: widget.onToggleConnection)
                                        : FittedBox(
                                            fit: BoxFit.contain,
                                            child: SsrvpnPowerButton(
                                                statusText: _statusText,
                                                size: (width * .64)
                                                    .clamp(160.0, 280.0),
                                                isConnected: widget.isConnected,
                                                isConnecting:
                                                    widget.isConnecting,
                                                hasConnectionError:
                                                    widget.errorMessage != null,
                                                onTap: widget
                                                    .onToggleConnection))),
                                LayoutId(
                                    id: _ThemedPart.hint,
                                    child: _connectionProgress != null
                                        ? _buildConnectionProgress()
                                        : const SizedBox.shrink()),
                                LayoutId(
                                    id: _ThemedPart.node,
                                    child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: SizedBox(
                                            width: contentWidth,
                                            child: _ThemedNodeCard(
                                                node: widget.selectedNode,
                                                latency: widget.selectedLatency,
                                                countryCode:
                                                    widget.selectedCountryCode,
                                                onTap: widget.onOpenNodes)))),
                                LayoutId(
                                    id: _ThemedPart.ip, child: _publicIpCard()),
                                if (widget.showModeControls)
                                  LayoutId(
                                      id: _ThemedPart.modes,
                                      child: _modeControls()),
                                if (widget.errorMessage != null ||
                                    widget.connectionNotice != null)
                                  LayoutId(
                                      id: _ThemedPart.details,
                                      child: _ConnectionDetails(
                                          errorMessage: widget.errorMessage,
                                          connectionNotice:
                                              widget.connectionNotice,
                                          onShowLogs: widget.onShowLogs)),
                                if (widget.bottomContent != null)
                                  LayoutId(
                                      id: _ThemedPart.statistics,
                                      child: KeyedSubtree(
                                          key: _statisticsKey,
                                          child: widget.bottomContent!)),
                              ])));
                }))));
  }
}

class _ThemedHomeLayout extends MultiChildLayoutDelegate {
  _ThemedHomeLayout(
      {required this.centerY, required this.cloud, required this.illustrated});
  final double centerY;
  final bool cloud, illustrated;
  @override
  void performLayout(Size size) {
    Size measure(_ThemedPart part, double height) => layoutChild(
        part,
        BoxConstraints(
            maxWidth: size.width, maxHeight: height.clamp(0, size.height)));
    void place(_ThemedPart part, Size child, double top) =>
        positionChild(part, Offset((size.width - child.width) / 2, top));
    final node = measure(_ThemedPart.node, size.height * .22);
    final nodeTop =
        (centerY - node.height / 2).clamp(0.0, size.height - node.height);
    place(_ThemedPart.node, node, nodeTop);
    final contentWidth =
        cloud ? (size.width - 36).clamp(0.0, 440.0) : size.width;
    final ip = layoutChild(_ThemedPart.ip,
        BoxConstraints.tightFor(width: contentWidth, height: 42));
    final baseGap = (size.height * .016).clamp(12.0, 16.0);
    final available =
        (size.height - nodeTop - node.height + 8).clamp(0.0, size.height);
    final details = hasChild(_ThemedPart.details)
        ? measure(_ThemedPart.details, available * .25)
        : Size.zero;
    final slots = 2 +
        (hasChild(_ThemedPart.statistics) ? 1 : 0) +
        (hasChild(_ThemedPart.details) ? 1 : 0);
    final stats = hasChild(_ThemedPart.statistics)
        ? layoutChild(
            _ThemedPart.statistics,
            BoxConstraints(
                maxWidth: contentWidth,
                maxHeight:
                    (available - ip.height - details.height - slots * baseGap)
                        .clamp(0.0, size.height)))
        : Size.zero;
    final gap =
        ((available - ip.height - details.height - stats.height) / slots)
            .clamp(0.0, size.height);
    var lower = nodeTop + node.height + gap;
    place(_ThemedPart.ip, ip, lower);
    lower += ip.height + gap;
    if (hasChild(_ThemedPart.details)) {
      place(_ThemedPart.details, details, lower);
      lower += details.height + gap;
    }
    if (hasChild(_ThemedPart.statistics)) {
      place(_ThemedPart.statistics, stats, lower);
    }
    final modeSpace =
        hasChild(_ThemedPart.modes) ? 48.0 + gap.clamp(8.0, 18.0) : 0.0;
    if (hasChild(_ThemedPart.modes)) {
      final modes = layoutChild(_ThemedPart.modes,
          BoxConstraints.tightFor(width: contentWidth, height: 48));
      place(_ThemedPart.modes, modes, nodeTop - modeSpace);
    }
    final hint = measure(_ThemedPart.hint, 42);
    final status = measure(_ThemedPart.status, 48);
    final header = cloud ? Size.zero : measure(_ThemedPart.header, 48);
    final powerHeight =
        (nodeTop - modeSpace - hint.height - status.height - header.height - 22)
            .clamp(0.0, size.height);
    final power = cloud
        ? layoutChild(_ThemedPart.power,
            BoxConstraints.tight(Size(size.width, powerHeight)))
        : measure(_ThemedPart.power, powerHeight);
    var top = 4.0;
    if (!cloud) {
      place(_ThemedPart.header, header, top);
      top += header.height + 4;
      if (!illustrated) {
        place(_ThemedPart.status, status, top);
        top += status.height + 4;
      }
    }
    place(_ThemedPart.power, power, top);
    top += power.height + 4;
    if (cloud || illustrated) {
      place(_ThemedPart.status, status, top);
      top += status.height + 4;
    }
    place(_ThemedPart.hint, hint, top);
  }

  @override
  bool shouldRelayout(_ThemedHomeLayout old) =>
      old.centerY != centerY ||
      old.cloud != cloud ||
      old.illustrated != illustrated;
}

class _ThemedNodeCard extends StatelessWidget {
  const _ThemedNodeCard(
      {required this.node,
      required this.latency,
      required this.countryCode,
      required this.onTap});
  final ProxyNode? node;
  final int? latency;
  final String? countryCode;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = SsrvpnTheme.of(context);
    final paper = colors.variant == AppThemeVariant.pixel &&
        !MediaQuery.highContrastOf(context);
    final ink = paper ? const Color(0xFF16392B) : colors.textPrimary;
    final secondary = paper ? const Color(0xFF45654B) : colors.textSecondary;
    final name =
        node == null ? '选择服务器' : nodeDisplayNameWithoutLeadingFlag(node!.name);
    final code =
        countryCode ?? (node == null ? 'UN' : countryCodeForProxyNode(node!));
    final latencyColor =
        latency == null || NodeDisplayPolicy.isLocalProbeBlocked(latency)
            ? colors.textSecondary
            : NodeDisplayPolicy.isTimeoutLatency(latency) || latency! >= 350
                ? colors.error
                : latency! < 180
                    ? (paper ? const Color(0xFF246347) : colors.success)
                    : colors.warning;
    return Semantics(
        button: true,
        label: '当前节点 $name，打开服务器选择',
        child: Material(
            color: Colors.transparent,
            child: InkWell(
                key: const Key('ssrvpn-current-node-card'),
                onTap: onTap,
                borderRadius: BorderRadius.circular(26),
                child: SsrvpnLiquidSurface(
                    tint: paper ? const Color(0xFFEBDCB5) : null,
                    tintOpacity: paper ? 1 : null,
                    radius: 26,
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      Container(
                          width: paper ? 64 : 58,
                          height: paper ? 64 : 58,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                              color: colors.primary.withValues(alpha: .13),
                              borderRadius: BorderRadius.circular(18)),
                          child: paper
                              ? Image.asset(
                                  'assets/themes/pixel-country-${const {
                                    'JP',
                                    'HK',
                                    'SG',
                                    'US',
                                    'GB'
                                  }.contains(code) ? code : 'UN'}.webp',
                                  package: 'ssrvpn_shared',
                                  filterQuality: FilterQuality.none,
                                  excludeFromSemantics: true,
                                  errorBuilder: (_, __, ___) => CountryFlagIcon(
                                      countryCode: code, size: 36))
                              : CountryFlagIcon(countryCode: code, size: 36)),
                      const SizedBox(width: 14),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                            if (!paper)
                              Text('当前节点',
                                  style: TextStyle(
                                      color: secondary, fontSize: 13)),
                            const SizedBox(height: 3),
                            Tooltip(
                                message: name,
                                child: Text(name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: ink,
                                        fontSize: 19,
                                        fontWeight: FontWeight.w700))),
                            const SizedBox(height: 2),
                            Text(NodeDisplayPolicy.latencyText(latency),
                                style: TextStyle(
                                    color: latencyColor,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600))
                          ])),
                      Icon(
                          paper
                              ? Icons.arrow_forward_ios_rounded
                              : Icons.chevron_right_rounded,
                          color: secondary,
                          size: 28),
                    ])))));
  }
}
