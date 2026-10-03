import 'package:flutter/material.dart';

/// Shared raised material: a broad cast shadow and a softly lit upper face.
/// The fill stays close to the canvas; depth is carried by light, not outlines.
BoxDecoration ssrvpnSoftDecoration(
        {double radius = 26,
        bool circular = false,
        bool floating = false,
        Color? tint,
        Color? borderColor}) =>
    BoxDecoration(
      shape: circular ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circular ? null : BorderRadius.circular(radius),
      border: borderColor == null ? null : Border.all(color: borderColor),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          for (final color in const [Color(0xFFE9EDF2), Color(0xFFE2E7ED)])
            tint == null
                ? color
                : Color.alphaBlend(tint.withValues(alpha: .1), color),
        ],
      ),
      boxShadow: floating
          ? const [
              BoxShadow(
                  color: Color(0x44000000),
                  offset: Offset(0, 10),
                  blurRadius: 26)
            ]
          : const [
              BoxShadow(
                  color: Color(0xE6FFFFFF),
                  offset: Offset(-7, -7),
                  blurRadius: 16),
              BoxShadow(
                  color: Color(0x99A6B0BF),
                  offset: Offset(7, 9),
                  blurRadius: 16),
              BoxShadow(
                  color: Color(0x35B1BAC8),
                  offset: Offset(2, 3),
                  blurRadius: 4),
            ],
    );
