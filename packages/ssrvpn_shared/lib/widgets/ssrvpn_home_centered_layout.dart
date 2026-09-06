part of 'ssrvpn_home_overview.dart';

enum _HomePart { header, status, power, node, details, statistics }

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

    final node = layoutChild(_HomePart.node,
        BoxConstraints(maxWidth: nodeWidth.clamp(0, size.width)));
    final nodeTop = centerY - node.height / 2;
    place(_HomePart.node, node, nodeTop);

    final header = measure(_HomePart.header, height: 48);
    final status = measure(_HomePart.status);
    final diameter =
        (nodeTop - header.height - status.height - 34).clamp(48.0, powerSize);
    final power = layoutChild(
        _HomePart.power, BoxConstraints.tight(Size.square(diameter)));
    final spare =
        (nodeTop - header.height - status.height - power.height - 34) / 3;
    place(_HomePart.header, header, 0);
    final statusTop = header.height + 12 + spare;
    place(_HomePart.status, status, statusTop);
    place(_HomePart.power, power, statusTop + status.height + 10 + spare);

    var lowerTop = nodeTop + node.height + 12;
    if (hasChild(_HomePart.details)) {
      final details = measure(_HomePart.details, height: 60);
      place(_HomePart.details, details, lowerTop);
      lowerTop += details.height + 12;
    }
    if (hasChild(_HomePart.statistics)) {
      final statistics =
          measure(_HomePart.statistics, height: size.height - lowerTop);
      place(_HomePart.statistics, statistics, size.height - statistics.height);
    }
  }

  @override
  bool shouldRelayout(_CenteredHomeLayout oldDelegate) =>
      centerY != oldDelegate.centerY ||
      powerSize != oldDelegate.powerSize ||
      nodeWidth != oldDelegate.nodeWidth;
}

// Keep the tall layout separate from the already accepted compact geometry.
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
              nodeWidth: compact ? 300 : SsrvpnUiTokens.currentNodeMaxWidth),
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
            LayoutId(id: _HomePart.node, child: node),
            if (detailsVisible) LayoutId(id: _HomePart.details, child: details),
            if (widget.bottomContent != null)
              LayoutId(
                  id: _HomePart.statistics,
                  child: KeyedSubtree(
                      key: _statisticsKey, child: widget.bottomContent!)),
          ]);
}
