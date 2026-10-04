part of 'ssrvpn_home_overview.dart';

enum _ThemedPart { header, status, power, hint, node, ip, details, statistics }

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
                      cloud ? box.maxWidth : box.maxWidth.clamp(240.0, 480.0);
                  final contentWidth =
                      cloud ? (width - 36).clamp(0.0, 444.0) : width;
                  final header = Padding(
                      padding: EdgeInsets.symmetric(horizontal: cloud ? 18 : 0),
                      child: SizedBox(
                          height: 48,
                          child: _HomeHeader(
                              compact: width < 400,
                              onShowAbout: widget.onShowAbout,
                              onShowTutorial: widget.onShowTutorial)));
                  final status = Semantics(
                      liveRegion: true,
                      child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 7),
                          decoration: BoxDecoration(
                              color: colors.surface.withValues(alpha: .86),
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                  color: _statusColor.withValues(alpha: .2))),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.circle, size: 12, color: _statusColor),
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
                                  centerY: centerY, cloud: cloud),
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
                                    id: _ThemedPart.ip,
                                    child: TextButton.icon(
                                        key: const Key('home-public-ip'),
                                        onPressed: widget.isRefreshingPublicIp
                                            ? null
                                            : widget.onRefreshPublicIp,
                                        icon: Icon(Icons.public_rounded,
                                            size: 18,
                                            color: colors.textSecondary),
                                        label: Text(
                                            widget.isRefreshingPublicIp
                                                ? '查询中…'
                                                : widget.publicIpError ??
                                                    widget.publicIpv4 ??
                                                    '获取公网 IPv4',
                                            style: TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w600,
                                                color: colors.textSecondary)),
                                        style: TextButton.styleFrom(
                                            minimumSize: const Size(48, 40),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4),
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap))),
                                if (widget.errorMessage != null ||
                                    widget.connectionNotice != null)
                                  LayoutId(
                                      id: _ThemedPart.details,
                                      child: _ConnectionDetails(
                                          errorMessage: widget.errorMessage,
                                          connectionNotice:
                                              widget.connectionNotice,
                                          publicIpv4: widget.publicIpv4,
                                          publicIpError: widget.publicIpError,
                                          isRefreshingPublicIp:
                                              widget.isRefreshingPublicIp,
                                          onShowLogs: widget.onShowLogs,
                                          onRefreshPublicIp:
                                              widget.onRefreshPublicIp)),
                                if (widget.bottomContent != null)
                                  LayoutId(
                                      id: _ThemedPart.statistics,
                                      child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment: Alignment.bottomCenter,
                                          child: SizedBox(
                                              width: contentWidth,
                                              child: KeyedSubtree(
                                                  key: _statisticsKey,
                                                  child:
                                                      widget.bottomContent!)))),
                              ])));
                }))));
  }
}

class _ThemedHomeLayout extends MultiChildLayoutDelegate {
  _ThemedHomeLayout({required this.centerY, required this.cloud});
  final double centerY;
  final bool cloud;
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
    final hint = measure(_ThemedPart.hint, 42);
    final status = measure(_ThemedPart.status, 48);
    final header = cloud ? Size.zero : measure(_ThemedPart.header, 48);
    final powerHeight =
        (nodeTop - hint.height - status.height - header.height - 22)
            .clamp(0.0, size.height);
    final power = cloud
        ? layoutChild(_ThemedPart.power,
            BoxConstraints.tight(Size(size.width, powerHeight)))
        : measure(_ThemedPart.power, powerHeight);
    var top = 4.0;
    if (!cloud) {
      place(_ThemedPart.header, header, top);
      top += header.height + 4;
      place(_ThemedPart.status, status, top);
      top += status.height + 4;
    }
    place(_ThemedPart.power, power, top);
    top += power.height + 4;
    if (cloud) {
      place(_ThemedPart.status, status, top);
      top += status.height + 4;
    }
    place(_ThemedPart.hint, hint, top);
    final ip = measure(_ThemedPart.ip, 44);
    place(_ThemedPart.ip, ip, nodeTop + node.height + 4);
    var lower = nodeTop + node.height + ip.height + 8;
    if (hasChild(_ThemedPart.details)) {
      final details = measure(_ThemedPart.details, (size.height - lower) * .30);
      place(_ThemedPart.details, details, lower);
      lower += details.height + 4;
    }
    if (hasChild(_ThemedPart.statistics)) {
      final stats = measure(_ThemedPart.statistics, size.height - lower - 4);
      place(_ThemedPart.statistics, stats, size.height - stats.height - 4);
    }
  }

  @override
  bool shouldRelayout(_ThemedHomeLayout old) =>
      old.centerY != centerY || old.cloud != cloud;
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
                    ? colors.success
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
                child: SsrvpnSurfaceCard(
                    radius: 26,
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      Container(
                          width: 58,
                          height: 58,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                              color: colors.primary.withValues(alpha: .13),
                              borderRadius: BorderRadius.circular(18)),
                          child: CountryFlagIcon(countryCode: code, size: 36)),
                      const SizedBox(width: 14),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                            Text('当前节点',
                                style: TextStyle(
                                    color: colors.textSecondary, fontSize: 13)),
                            const SizedBox(height: 3),
                            Tooltip(
                                message: name,
                                child: Text(name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: colors.textPrimary,
                                        fontSize: 19,
                                        fontWeight: FontWeight.w700))),
                            const SizedBox(height: 2),
                            Text(NodeDisplayPolicy.latencyText(latency),
                                style: TextStyle(
                                    color: latencyColor,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600))
                          ])),
                      Icon(Icons.chevron_right_rounded,
                          color: colors.textSecondary, size: 28),
                    ])))));
  }
}
