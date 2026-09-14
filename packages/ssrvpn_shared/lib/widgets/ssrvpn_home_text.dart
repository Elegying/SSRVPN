import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Local text fitting changes the actual font/line height, never a render transform.
class SsrvpnHomeText extends StatefulWidget {
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
  State<SsrvpnHomeText> createState() => _SsrvpnHomeTextState();
}

class _SsrvpnHomeTextState extends State<SsrvpnHomeText> {
  // One entry per mounted label; live values with a fixed reference reuse it.
  // Constraints, typography and system font changes invalidate the result.
  Object? _fitKey;
  double? _fittedFont;

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
  }

  void _fontsChanged() {
    setState(() => _fitKey = null);
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final base = DefaultTextStyle.of(context).style.merge(widget.style);
        var font = MediaQuery.textScalerOf(context).scale(base.fontSize ?? 14);
        font = math.min(font, widget.maxFontSize ?? double.infinity);
        final direction = Directionality.of(context);
        bool fits(double size) {
          final painter = TextPainter(
              text: TextSpan(
                  text: widget.fitReference ?? widget.data,
                  style:
                      base.copyWith(fontSize: size, height: widget.lineHeight)),
              textDirection: direction,
              maxLines: widget.maxLines)
            ..layout(maxWidth: constraints.maxWidth);
          final fits = painter
                  .computeLineMetrics()
                  .every((line) => line.width <= constraints.maxWidth + .01) &&
              !painter.didExceedMaxLines &&
              painter.height <= constraints.maxHeight;
          painter.dispose();
          return fits;
        }

        final fitKey = (
          constraints,
          base,
          font,
          direction,
          widget.fitReference ?? widget.data,
          widget.lineHeight,
          widget.minFontSize,
          widget.maxLines,
        );
        if (_fitKey == fitKey) {
          font = _fittedFont!;
        } else {
          var low = math.min(font, widget.minFontSize), high = font;
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
          _fitKey = fitKey;
          _fittedFont = font;
        }
        return Text(widget.data,
            style: base.copyWith(fontSize: font, height: widget.lineHeight),
            textScaler: TextScaler.noScaling,
            strutStyle: StrutStyle(
                fontSize: font,
                height: widget.lineHeight,
                forceStrutHeight: true),
            maxLines: widget.maxLines,
            overflow: widget.overflow,
            textAlign: widget.textAlign);
      });
}
