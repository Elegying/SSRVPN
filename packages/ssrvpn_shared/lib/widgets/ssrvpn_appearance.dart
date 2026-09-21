import 'dart:io';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as glass;
import '../models/app_settings.dart';

class SsrvpnAppearance extends InheritedWidget {
  const SsrvpnAppearance(
      {super.key,
      required this.level,
      required this.background,
      required this.imagePath,
      required this.dynamicBackground,
      required super.child});
  final GlassEffectLevel? level;
  final BackgroundStyle background;
  final String imagePath;
  final bool dynamicBackground;
  static SsrvpnAppearance? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SsrvpnAppearance>();
  @override
  bool updateShouldNotify(SsrvpnAppearance oldWidget) =>
      level != oldWidget.level ||
      background != oldWidget.background ||
      imagePath != oldWidget.imagePath ||
      dynamicBackground != oldWidget.dynamicBackground;
}

Color? ssrvpnBackgroundColor(BackgroundStyle style) => switch (style) {
      BackgroundStyle.blue => const Color(0xFF173F78),
      BackgroundStyle.gray => const Color(0xFF353B45),
      BackgroundStyle.forest => const Color(0xFF164B3F),
      BackgroundStyle.orange => const Color(0xFF904514),
      BackgroundStyle.yellow => const Color(0xFF75620E),
      BackgroundStyle.deepBlue => const Color(0xFF071A3A),
      BackgroundStyle.black => Colors.black,
      _ => null,
    };

class SsrvpnCustomBackground extends StatelessWidget {
  const SsrvpnCustomBackground({super.key, required this.path});
  final String path;
  @override
  Widget build(BuildContext context) => Image.file(File(path),
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      color: Colors.black
          .withValues(alpha: MediaQuery.highContrastOf(context) ? .75 : .55),
      colorBlendMode: BlendMode.srcATop,
      errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFF173F78)));
}

/// Applies the chosen quality to both SSRVPN surfaces and library controls.
/// The scope stays mounted across preference changes so forms retain state.
class SsrvpnAppearanceScope extends StatelessWidget {
  const SsrvpnAppearanceScope(
      {super.key, required this.settings, required this.child});
  final AppSettings settings;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final quality = switch (settings.glassEffectLevel) {
      GlassEffectLevel.none ||
      GlassEffectLevel.low =>
        glass.GlassQuality.minimal,
      GlassEffectLevel.medium => glass.GlassQuality.standard,
      GlassEffectLevel.high => glass.GlassQuality.premium,
      null => glass.GlassAdaptiveScopeData.maybeOf(context)?.effectiveQuality ??
          glass.GlassQuality.premium,
    };
    return SsrvpnAppearance(
        level: settings.glassEffectLevel,
        background: settings.backgroundStyle,
        imagePath: settings.customBackgroundPath,
        dynamicBackground: settings.dynamicBackground,
        child: glass.GlassAdaptiveScope(
            minQuality: quality,
            maxQuality: quality,
            initialQuality: quality,
            child: child));
  }
}

String ssrvpnBackgroundLabel(BackgroundStyle style) => switch (style) {
      BackgroundStyle.flowing => '壁纸',
      BackgroundStyle.blue => '蓝',
      BackgroundStyle.gray => '灰',
      BackgroundStyle.forest => '墨绿',
      BackgroundStyle.orange => '橙',
      BackgroundStyle.yellow => '黄',
      BackgroundStyle.custom => '自定义',
      BackgroundStyle.deepBlue => '深蓝',
      BackgroundStyle.black => '纯黑',
    };
