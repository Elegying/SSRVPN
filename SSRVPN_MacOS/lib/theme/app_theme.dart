import 'package:flutter/material.dart';

/// SSRVPN Theme — Linear / Vercel 级质感
class AppTheme {
  // ─── 品牌色 ───
  static const primary = Color(0xFF2F6BFF);
  static const primaryHover = Color(0xFF5B8CFF);
  static const primaryMuted = Color(0xFF1E49D8);
  static const accentColor = Color(0xFF14B8A6);

  // ─── 状态色 ───
  static const success = Color(0xFF18A957);
  static const successMuted = Color(0xFF0E7A3E);
  static const warning = Color(0xFFF59E0B);
  static const error = Color(0xFFEF4444);

  // ─── 暗色层级 ───
  static const bg = Color(0xFF08090B);
  static const surface = Color(0xFF101114);
  static const card = Color(0xFF15171B);
  static const cardHover = Color(0xFF1C2026);
  static const border = Color(0xFF2A2E36);
  static const borderLight = Color(0xFF3A414D);

  // ─── 文字 ───
  static const textPrimary = Color(0xFFF4F6F8);
  static const textSecondary = Color(0xFFA4ACB8);
  static const textTertiary = Color(0xFF717B8A);

  // ─── 亮色 ───
  static const lightBg = Color(0xFFF4F6F8);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightBorder = Color(0xFFD8DEE8);
  static const lightTextPrimary = Color(0xFF111827);
  static const lightTextSecondary = Color(0xFF5F6B7A);
  static const lightTextHint = Color(0xFF8A94A6);

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        primaryColor: primary,
        scaffoldBackgroundColor: bg,
        fontFamily: 'Segoe UI',
        colorScheme: const ColorScheme.dark(
          primary: primary,
          secondary: Color(0xFF06B6D4),
          surface: surface,
          error: error,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: textPrimary,
          onError: Colors.white,
          outline: borderLight,
          outlineVariant: border,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: textPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
              color: textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: 0),
        ),
        cardTheme: CardThemeData(
          color: card,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: border, width: 0.5)),
          margin: EdgeInsets.zero,
        ),
        dividerTheme:
            const DividerThemeData(color: border, thickness: 0.5, space: 0),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: border)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: border)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: primary, width: 1.5)),
          errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: error)),
          hintStyle: const TextStyle(color: textTertiary, fontSize: 14),
          labelStyle: const TextStyle(color: textSecondary, fontSize: 14),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0,
              textStyle: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0)),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
              foregroundColor: primaryHover,
              textStyle:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected) ? Colors.white : textTertiary),
          trackColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? primary : border),
          trackOutlineColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected)
                  ? Colors.transparent
                  : borderLight),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: card,
          contentTextStyle: const TextStyle(color: textPrimary, fontSize: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          behavior: SnackBarBehavior.floating,
        ),
        dialogTheme: DialogThemeData(
            backgroundColor: surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18))),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
              color: textPrimary,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: 0),
          headlineMedium: TextStyle(
              color: textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: 0),
          titleLarge: TextStyle(
              color: textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: 0),
          titleMedium: TextStyle(
              color: textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 0),
          bodyLarge:
              TextStyle(color: textPrimary, fontSize: 14, letterSpacing: 0),
          bodyMedium:
              TextStyle(color: textSecondary, fontSize: 13, letterSpacing: 0),
          bodySmall:
              TextStyle(color: textTertiary, fontSize: 12, letterSpacing: 0),
          labelLarge: TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
        ),
      );

  static ThemeData get light => ThemeData(
        brightness: Brightness.light,
        useMaterial3: true,
        primaryColor: primary,
        scaffoldBackgroundColor: lightBg,
        fontFamily: 'Segoe UI',
        colorScheme: const ColorScheme.light(
          primary: primary,
          secondary: Color(0xFF06B6D4),
          surface: lightSurface,
          error: error,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: lightTextPrimary,
          onError: Colors.white,
          outline: lightBorder,
          outlineVariant: Color(0xFFD4D4D4),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: lightTextPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
              color: lightTextPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600),
        ),
        cardTheme: CardThemeData(
          color: lightCard,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: lightBorder, width: 0.5)),
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: lightBg,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: lightBorder)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: lightBorder)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: primary, width: 1.5)),
          hintStyle: const TextStyle(color: lightTextSecondary, fontSize: 14),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected)
                  ? Colors.white
                  : lightTextSecondary),
          trackColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected)
                  ? primary
                  : const Color(0xFFE5E5E5)),
        ),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
              color: lightTextPrimary,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6),
          headlineMedium: TextStyle(
              color: lightTextPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4),
          titleLarge: TextStyle(
              color: lightTextPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600),
          titleMedium: TextStyle(
              color: lightTextPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(color: lightTextPrimary, fontSize: 14),
          bodyMedium: TextStyle(color: lightTextSecondary, fontSize: 13),
          bodySmall: TextStyle(color: lightTextSecondary, fontSize: 12),
        ),
      );
}

extension SnackBarX on BuildContext {
  void showSnack(String message,
      {Color? backgroundColor,
      Duration duration = const Duration(seconds: 2)}) {
    ScaffoldMessenger.of(this).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      content: Text(message),
      backgroundColor: backgroundColor,
      duration: duration,
    ));
  }
}
