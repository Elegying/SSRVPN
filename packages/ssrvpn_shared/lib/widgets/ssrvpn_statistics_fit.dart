import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Keep the panel's outer edges aligned when a short canvas compresses its
/// contents. Expanding the layout width before uniform scaling avoids narrow
/// floating cards and preserves the aspect ratio of icons and text.
class SsrvpnStatisticsFit extends StatelessWidget {
  const SsrvpnStatisticsFit(
      {super.key, required this.naturalHeight, required this.child});
  final double naturalHeight;
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final factor = box.hasBoundedHeight
            ? math.min(1.0, box.maxHeight / naturalHeight).clamp(.01, 1.0)
            : 1.0;
        return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.bottomCenter,
            child: SizedBox(width: box.maxWidth / factor, child: child));
      });
}
