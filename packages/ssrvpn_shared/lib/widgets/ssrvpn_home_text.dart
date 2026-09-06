import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Local text fitting changes the actual font/line height, never a render transform.
class SsrvpnHomeText extends StatelessWidget {
  const SsrvpnHomeText(this.data,
      {super.key,
      this.style,
      this.maxLines = 1,
      this.overflow,
      this.textAlign,
      this.maxFontSize,
      this.fitReference,
      this.lineHeight = 1.1,
      this.minFontSize = 10});
  final String data;
  final String? fitReference;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final double? maxFontSize;
  final double minFontSize;
  final double lineHeight;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final base = DefaultTextStyle.of(context).style.merge(style);
        var font = MediaQuery.textScalerOf(context).scale(base.fontSize ?? 14);
        font = math.min(font, maxFontSize ?? double.infinity);
        final direction = Directionality.of(context);
        bool fits(double size) {
          final painter = TextPainter(
              text: TextSpan(
                  text: fitReference ?? data,
                  style: base.copyWith(fontSize: size, height: lineHeight)),
              textDirection: direction,
              maxLines: maxLines)
            ..layout(maxWidth: constraints.maxWidth);
          final fits = painter
                  .computeLineMetrics()
                  .every((line) => line.width <= constraints.maxWidth + .01) &&
              !painter.didExceedMaxLines &&
              painter.height <= constraints.maxHeight;
          painter.dispose();
          return fits;
        }

        var low = math.min(font, minFontSize), high = font;
        if (!fits(font)) {
          for (var i = 0; i < 10; i++) {
            final middle = (low + high) / 2;
            if (fits(middle)) {
              low = middle;
            } else {
              high = middle;
            }
          }
          font = low;
        }
        return Text(data,
            style: base.copyWith(fontSize: font, height: lineHeight),
            textScaler: TextScaler.noScaling,
            strutStyle: StrutStyle(
                fontSize: font, height: lineHeight, forceStrutHeight: true),
            maxLines: maxLines,
            overflow: overflow,
            textAlign: textAlign);
      });
}
