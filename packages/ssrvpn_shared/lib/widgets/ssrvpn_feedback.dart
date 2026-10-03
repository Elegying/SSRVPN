import 'package:flutter/material.dart';

/// Choose the stronger black/white contrast for an opaque status fill.
Color ssrvpnForegroundOn(Color background) =>
    background.computeLuminance() > .179 ? Colors.black : Colors.white;

/// Explicit status fills must not inherit the page's light/dark text palette.
SnackBar ssrvpnSnackBar({
  required Widget content,
  Color? backgroundColor,
  SnackBarBehavior? behavior,
  EdgeInsetsGeometry? margin,
  Duration duration = const Duration(seconds: 4),
}) =>
    SnackBar(
      content: backgroundColor == null
          ? content
          : DefaultTextStyle.merge(
              style: TextStyle(color: ssrvpnForegroundOn(backgroundColor)),
              child: content),
      backgroundColor: backgroundColor,
      behavior: behavior,
      margin: margin,
      duration: duration,
    );
