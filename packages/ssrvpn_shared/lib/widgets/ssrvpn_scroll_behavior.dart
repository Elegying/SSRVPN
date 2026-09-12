import 'package:flutter/material.dart';

/// Keep platform scrolling, without the visual scrollbar on any client.
class SsrvpnScrollBehavior extends MaterialScrollBehavior {
  const SsrvpnScrollBehavior();
  @override
  Widget buildScrollbar(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}
