import 'package:flutter/material.dart';
import '../models/app_settings.dart';

/// One semantic palette for every route, popup and control. No global mutable
/// colors: captured Material themes keep menus consistent with their owner.
class SsrvpnTheme extends ThemeExtension<SsrvpnTheme> {
  const SsrvpnTheme(this.variant);
  final AppThemeVariant variant;
  static SsrvpnTheme of(BuildContext context) =>
      Theme.of(context).extension<SsrvpnTheme>() ??
      const SsrvpnTheme(AppThemeVariant.defaultTheme);
  bool get isDefault => variant == AppThemeVariant.defaultTheme;
  bool get isSoft => variant == AppThemeVariant.soft;
  bool get isLight =>
      isSoft ||
      variant == AppThemeVariant.sakura ||
      variant == AppThemeVariant.cloud;
  String get name => switch (variant) {
        AppThemeVariant.defaultTheme => '默认',
        AppThemeVariant.aurora => '曜石极光',
        AppThemeVariant.sakura => '樱花晴空',
        AppThemeVariant.cloud => '云朵游乐场',
        AppThemeVariant.dusk => '暮色山境',
        AppThemeVariant.soft => 'Soft 新拟态',
      };
  String get assetName => isDefault ? 'default' : variant.name;
  String get icon => 'assets/themes/$assetName-icon.webp';
  String get wallpaper => isDefault
      ? 'assets/backgrounds/network-glass-deep.webp'
      : variant == AppThemeVariant.cloud
          ? 'assets/themes/cloud-hero.webp'
          : 'assets/themes/$assetName.webp';
  Color get background => switch (variant) {
        AppThemeVariant.defaultTheme => const Color(0xFF0A1020),
        AppThemeVariant.aurora => const Color(0xFF050B17),
        AppThemeVariant.sakura => const Color(0xFFFFF8FA),
        AppThemeVariant.cloud => const Color(0xFFFFF8E9),
        AppThemeVariant.dusk => const Color(0xFF21192F),
        AppThemeVariant.soft => const Color(0xFFE4E9EF),
      };
  Color get surface => switch (variant) {
        AppThemeVariant.defaultTheme => const Color(0xFF242641),
        AppThemeVariant.aurora => const Color(0xFF111D30),
        AppThemeVariant.sakura => const Color(0xFFFFFDFE),
        AppThemeVariant.cloud => const Color(0xFFFFFEFA),
        AppThemeVariant.dusk => const Color(0xFF392B45),
        AppThemeVariant.soft => const Color(0xFFE4E9EF),
      };
  Color get backgroundRaised => isDefault ? const Color(0xFF14152F) : surface;
  Color get surfaceStrong => isDefault
      ? const Color(0xFF2C2E4B)
      : Color.alphaBlend(primary.withValues(alpha: .08), surface);
  Color get primary => switch (variant) {
        AppThemeVariant.defaultTheme => const Color(0xFF8A84FF),
        AppThemeVariant.aurora => const Color(0xFF48E7CF),
        AppThemeVariant.sakura => const Color(0xFFB83570),
        AppThemeVariant.cloud => const Color(0xFF176BC2),
        AppThemeVariant.dusk => const Color(0xFFFFB58D),
        AppThemeVariant.soft => const Color(0xFF287E8C),
      };
  Color get primaryBlue => isDefault ? const Color(0xFF3675FF) : primary;
  Color get accent => switch (variant) {
        AppThemeVariant.defaultTheme => const Color(0xFF20C8B4),
        AppThemeVariant.aurora => const Color(0xFF86AEFF),
        AppThemeVariant.sakura => const Color(0xFF8354B3),
        AppThemeVariant.cloud => const Color(0xFFB06A08),
        AppThemeVariant.dusk => const Color(0xFFD5B5E6),
        AppThemeVariant.soft => const Color(0xFF586FAD),
      };
  Color get textPrimary => switch (variant) {
        AppThemeVariant.sakura => const Color(0xFF432039),
        AppThemeVariant.cloud => const Color(0xFF172D5B),
        AppThemeVariant.dusk => const Color(0xFFFFF3DA),
        AppThemeVariant.soft => const Color(0xFF27313D),
        _ => const Color(0xFFF5F7FF),
      };
  Color get textSecondary => switch (variant) {
        AppThemeVariant.defaultTheme => const Color(0xFFA7AFC2),
        AppThemeVariant.sakura => const Color(0xFF78586F),
        AppThemeVariant.cloud => const Color(0xFF506584),
        AppThemeVariant.dusk => const Color(0xFFC8BBD1),
        AppThemeVariant.soft => const Color(0xFF56616D),
        _ => const Color(0xFFAFBBD0),
      };
  Color get textTertiary => isDefault ? const Color(0xFF929BB1) : textSecondary;
  Color get border => isSoft
      ? const Color(0xFFD3DCE3)
      : variant == AppThemeVariant.cloud
          ? Colors.white
          : isDefault
              ? const Color(0x33FFFFFF)
              : primary.withValues(alpha: isLight ? .22 : .25);
  Color get success => isDefault
      ? const Color(0xFF29C978)
      : isLight
          ? const Color(0xFF087A4D)
          : const Color(0xFF5FE4A5);
  Color get warning => isDefault
      ? const Color(0xFFF3B83F)
      : isLight
          ? const Color(0xFF925100)
          : const Color(0xFFFFCC7C);
  Color get error => isDefault
      ? const Color(0xFFE35D6A)
      : isLight
          ? const Color(0xFFB32642)
          : const Color(0xFFFF8797);
  Color get onPrimary => isDefault || isLight ? Colors.white : background;

  ThemeData material(ThemeData base) {
    final scheme = ColorScheme.fromSeed(
            seedColor: primary,
            brightness: isLight ? Brightness.light : Brightness.dark)
        .copyWith(
      primary: primary,
      onPrimary: onPrimary,
      secondary: accent,
      surface: surface,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      error: error,
      outline: border,
      outlineVariant: border,
      surfaceContainerHighest: surfaceStrong,
    );
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      platform: base.platform,
      visualDensity: base.visualDensity,
      scaffoldBackgroundColor: background,
      textTheme: base.textTheme
          .apply(bodyColor: textPrimary, displayColor: textPrimary),
      extensions: [this],
    );
    return theme.copyWith(
      appBarTheme: AppBarTheme(
          backgroundColor: surface, foregroundColor: textPrimary, elevation: 0),
      dividerColor: border,
      iconTheme: IconThemeData(color: textSecondary),
      dialogTheme: DialogThemeData(
          backgroundColor: surface, surfaceTintColor: Colors.transparent),
      popupMenuTheme: PopupMenuThemeData(
          color: surface,
          surfaceTintColor: Colors.transparent,
          textStyle: theme.textTheme.bodyMedium),
      bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: surface, surfaceTintColor: Colors.transparent),
      inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surfaceStrong,
          labelStyle: TextStyle(color: textSecondary),
          hintStyle: TextStyle(color: textSecondary),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: border)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: border)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: primary, width: 2)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14)),
      snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: surfaceStrong,
          contentTextStyle: TextStyle(color: textPrimary)),
      tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
              color: surfaceStrong,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: border)),
          textStyle: TextStyle(color: textPrimary)),
    );
  }

  @override
  SsrvpnTheme copyWith({AppThemeVariant? variant}) =>
      SsrvpnTheme(variant ?? this.variant);
  @override
  SsrvpnTheme lerp(covariant SsrvpnTheme? other, double t) =>
      t < .5 ? this : other ?? this;
}
