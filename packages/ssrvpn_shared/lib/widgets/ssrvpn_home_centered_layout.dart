part of 'ssrvpn_home_overview.dart';

enum _HomePart {
  header,
  status,
  power,
  progress,
  node,
  ip,
  modes,
  details,
  statistics
}

/// The card itself anchors the vertical layout; account cards never move it.
class _CenteredHomeLayout extends MultiChildLayoutDelegate {
  _CenteredHomeLayout({
    required this.centerY,
    required this.powerSize,
    required this.nodeWidth,
  });

  final double centerY, powerSize, nodeWidth;

  @override
  void performLayout(Size size) {
    Size measure(_HomePart part, {double? width, double? height}) =>
        layoutChild(
            part,
            BoxConstraints(
                maxWidth: (width ?? size.width).clamp(0, size.width),
                maxHeight: (height ?? size.height).clamp(0, size.height)));
    void place(_HomePart part, Size child, double top) =>
        positionChild(part, Offset((size.width - child.width) / 2, top));

    final node = layoutChild(
        _HomePart.node,
        BoxConstraints(
            maxWidth: nodeWidth.clamp(0, size.width),
            maxHeight: size.height * .22));
    final nodeTop = centerY - node.height / 2;
    place(_HomePart.node, node, nodeTop);

    final ip = layoutChild(
        _HomePart.ip, BoxConstraints.tightFor(width: size.width, height: 42));
    final available =
        (size.height - nodeTop - node.height + 12).clamp(0.0, size.height);
    final details = hasChild(_HomePart.details)
        ? measure(_HomePart.details, height: available * .25)
        : Size.zero;
    final slots = 2 +
        (hasChild(_HomePart.statistics) ? 1 : 0) +
        (hasChild(_HomePart.details) ? 1 : 0);
    final baseGap = (size.height * .016).clamp(12.0, 16.0);
    final statistics = hasChild(_HomePart.statistics)
        ? measure(_HomePart.statistics,
            height: (available - ip.height - details.height - slots * baseGap)
                .clamp(0.0, size.height))
        : Size.zero;
    final gap =
        ((available - ip.height - details.height - statistics.height) / slots)
            .clamp(0.0, size.height);
    var lower = nodeTop + node.height + gap;
    place(_HomePart.ip, ip, lower);
    lower += ip.height + gap;
    if (hasChild(_HomePart.details)) {
      place(_HomePart.details, details, lower);
      lower += details.height + gap;
    }
    if (hasChild(_HomePart.statistics)) {
      place(_HomePart.statistics, statistics, lower);
    }
    final modeSpace =
        hasChild(_HomePart.modes) ? 48.0 + gap.clamp(8.0, 18.0) : 0.0;
    if (hasChild(_HomePart.modes)) {
      final modes = layoutChild(_HomePart.modes,
          BoxConstraints.tightFor(width: size.width, height: 48));
      place(_HomePart.modes, modes, nodeTop - modeSpace);
    }
    final header = measure(_HomePart.header, height: 48);
    final status = measure(_HomePart.status);
    final progress = hasChild(_HomePart.progress)
        ? measure(_HomePart.progress, height: 60)
        : Size.zero;
    final progressSpace = progress.height == 0 ? 0 : progress.height + 8;
    final diameter = (nodeTop -
            modeSpace -
            header.height -
            status.height -
            progressSpace -
            34)
        .clamp(48.0, powerSize);
    final power = layoutChild(
        _HomePart.power, BoxConstraints.tight(Size.square(diameter)));
    final spare = (nodeTop -
            modeSpace -
            header.height -
            status.height -
            power.height -
            progressSpace -
            34) /
        3;
    place(_HomePart.header, header, 0);
    final statusTop = header.height + 12 + spare;
    place(_HomePart.status, status, statusTop);
    place(_HomePart.power, power, statusTop + status.height + 10 + spare);

    if (hasChild(_HomePart.progress)) {
      place(_HomePart.progress, progress,
          statusTop + status.height + 10 + spare + power.height + 8);
    }
  }

  @override
  bool shouldRelayout(_CenteredHomeLayout oldDelegate) =>
      centerY != oldDelegate.centerY ||
      powerSize != oldDelegate.powerSize ||
      nodeWidth != oldDelegate.nodeWidth;
}

// All reference-canvas sizes share the same centered geometry.
extension _CenteredHomeContent on _HomeOverviewState {
  Widget _centeredHome({
    required double centerY,
    required double powerSize,
    required bool compact,
    required Widget status,
    required Widget node,
    required Widget details,
    required bool detailsVisible,
  }) =>
      CustomMultiChildLayout(
          delegate: _CenteredHomeLayout(
              centerY: centerY,
              powerSize: powerSize,
              nodeWidth: SsrvpnUiTokens.currentNodeMaxWidth),
          children: [
            LayoutId(
                id: _HomePart.header,
                child: SizedBox(
                    key: const Key('home-overview-header'),
                    height: 48,
                    child: _HomeHeader(
                        compact: compact,
                        onShowAbout: widget.onShowAbout,
                        onShowTutorial: widget.onShowTutorial))),
            LayoutId(id: _HomePart.status, child: status),
            LayoutId(
                id: _HomePart.power,
                child: LayoutBuilder(
                    builder: (context, box) => SsrvpnPowerButton(
                        size: box.maxWidth,
                        isConnected: widget.isConnected,
                        isConnecting: widget.isConnecting,
                        hasConnectionError: widget.errorMessage != null,
                        onTap: widget.onToggleConnection))),
            if (_connectionProgress != null)
              LayoutId(
                  id: _HomePart.progress, child: _buildConnectionProgress()),
            LayoutId(id: _HomePart.node, child: node),
            LayoutId(id: _HomePart.ip, child: _publicIpCard()),
            if (widget.showModeControls)
              LayoutId(id: _HomePart.modes, child: _modeControls()),
            if (detailsVisible) LayoutId(id: _HomePart.details, child: details),
            if (widget.bottomContent != null)
              LayoutId(
                  id: _HomePart.statistics,
                  child: KeyedSubtree(
                      key: _statisticsKey, child: widget.bottomContent!)),
          ]);
}
