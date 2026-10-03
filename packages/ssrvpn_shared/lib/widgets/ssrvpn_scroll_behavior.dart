import 'package:flutter/material.dart';

/// Desktop lists retain their platform scrollbar; touch clients stay compact.
class SsrvpnScrollBehavior extends MaterialScrollBehavior {
  const SsrvpnScrollBehavior();
  @override
  Widget buildScrollbar(
      BuildContext context, Widget child, ScrollableDetails details) {
    return switch (getPlatform(context)) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux =>
        super.buildScrollbar(context, child, details),
      _ => child,
    };
  }
}
