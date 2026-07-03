import 'package:flutter/material.dart';

/// SSRVPN Premium Theme — Android 版本
///
/// 配色对齐 macOS 桌面版，保留向后兼容的旧名称
class AppTheme {
  // ─── 品牌色 ───
  static const Color primaryColor = Color(0xFF2F6BFF); // 对齐 macOS
  static const Color primaryLight = Color(0xFF5B8CFF);
  static const Color primaryDark = Color(0xFF1E49D8);
  static const Color accentColor = Color(0xFF14B8A6); // 对齐 macOS

  // macOS 别名
  static const Color primary = primaryColor;
  static const Color primaryHover = primaryLight;
  static const Color primaryMuted = primaryDark;

  // ─── 状态色 ───
  static const Color successColor = Color(0xFF18A957); // 对齐 macOS
  static const Color successLight = Color(0xFF34D399);
  static const Color successMuted = Color(0xFF0E7A3E);
  static const Color warningColor = Color(0xFFF59E0B); // 对齐 macOS
  static const Color errorColor = Color(0xFFEF4444); // 对齐 macOS

  // macOS 别名
  static const Color success = successColor;
  static const Color warning = warningColor;
  static const Color error = errorColor;

  // ─── 暗色主题 ───
  static const Color darkBg = Color(0xFF08090B); // 对齐 macOS bg
  static const Color darkSurface = Color(0xFF101114); // 对齐 macOS surface
  static const Color darkCard = Color(0xFF15171B); // 对齐 macOS card
  static const Color darkCardHover = Color(0xFF1C2026);
  static const Color darkBorder = Color(0xFF2A2E36); // 对齐 macOS border
  static const Color darkBorderLight = Color(0xFF3A414D);
  static const Color darkTextPrimary = Color(0xFFF4F6F8);
  static const Color darkTextSecondary = Color(0xFFA4ACB8);
  static const Color darkTextHint = Color(0xFF717B8A);

  // macOS 别名
  static const Color bg = darkBg;
  static const Color surface = darkSurface;
  static const Color card = darkCard;
  static const Color cardHover = darkCardHover;
  static const Color border = darkBorder;
  static const Color borderLight = darkBorderLight;
  static const Color textPrimary = darkTextPrimary;
  static const Color textSecondary = darkTextSecondary;
  static const Color textTertiary = darkTextHint;

  // ─── 亮色主题 ───
  static const Color lightBg = Color(0xFFF4F6F8);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFD8DEE8);
  static const Color lightTextPrimary = Color(0xFF111827);
  static const Color lightTextSecondary = Color(0xFF5F6B7A);
  static const Color lightTextHint = Color(0xFF8A94A6);

  /// 暗色主题
  static ThemeData get darkTheme => ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        primaryColor: primaryColor,
        scaffoldBackgroundColor: darkBg,
        fontFamily: 'Segoe UI',
        colorScheme: const ColorScheme.dark(
          primary: primaryColor,
          secondary: accentColor,
          surface: darkSurface,
          error: errorColor,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: darkTextPrimary,
          onError: Colors.white,
          outline: darkBorderLight,
          outlineVariant: darkBorder,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: darkTextPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: darkTextPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
        cardTheme: CardThemeData(
          color: darkCard,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: darkBorder, width: 1),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
        dividerTheme: const DividerThemeData(
          color: darkBorder,
          thickness: 1,
          space: 1,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: darkCard,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: darkBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: darkBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: primaryColor, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: errorColor),
          ),
          hintStyle: const TextStyle(color: darkTextHint, fontSize: 14),
          labelStyle: const TextStyle(color: darkTextSecondary, fontSize: 14),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 0,
            textStyle: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.1),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: primaryLight,
            textStyle:
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return Colors.white;
            return darkTextHint;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return primaryColor;
            return darkCard;
          }),
          trackOutlineColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return Colors.transparent;
            }
            return darkBorderLight;
          }),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: darkCard,
          contentTextStyle:
              const TextStyle(color: darkTextPrimary, fontSize: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          behavior: SnackBarBehavior.floating,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: darkSurface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
              color: darkTextPrimary,
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5),
          headlineMedium: TextStyle(
              color: darkTextPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3),
          titleLarge: TextStyle(
              color: darkTextPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2),
          titleMedium: TextStyle(
              color: darkTextPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.1),
          bodyLarge: TextStyle(
              color: darkTextPrimary, fontSize: 15, letterSpacing: -0.1),
          bodyMedium: TextStyle(
              color: darkTextSecondary, fontSize: 14, letterSpacing: -0.1),
          bodySmall:
              TextStyle(color: darkTextHint, fontSize: 12, letterSpacing: 0),
          labelLarge: TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
        ),
      );

  /// 亮色主题
  static ThemeData get lightTheme => ThemeData(
        brightness: Brightness.light,
        useMaterial3: true,
        primaryColor: primaryColor,
        scaffoldBackgroundColor: lightBg,
        fontFamily: 'Segoe UI',
        colorScheme: const ColorScheme.light(
          primary: primaryColor,
          secondary: accentColor,
          surface: lightSurface,
          error: errorColor,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: lightTextPrimary,
          onError: Colors.white,
          outline: lightBorder,
          outlineVariant: Color(0xFFCBD5E1),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: lightTextPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: lightTextPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
        cardTheme: CardThemeData(
          color: lightCard,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: lightBorder, width: 1),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
        dividerTheme: const DividerThemeData(
          color: lightBorder,
          thickness: 1,
          space: 1,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: lightBg,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: lightBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: lightBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: primaryColor, width: 1.5),
          ),
          hintStyle: const TextStyle(color: lightTextHint, fontSize: 14),
          labelStyle: const TextStyle(color: lightTextSecondary, fontSize: 14),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 0,
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return Colors.white;
            return lightTextHint;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return primaryColor;
            return const Color(0xFFE2E8F0);
          }),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: lightCard,
          contentTextStyle:
              const TextStyle(color: lightTextPrimary, fontSize: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          behavior: SnackBarBehavior.floating,
        ),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
              color: lightTextPrimary,
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5),
          headlineMedium: TextStyle(
              color: lightTextPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3),
          titleLarge: TextStyle(
              color: lightTextPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2),
          titleMedium: TextStyle(
              color: lightTextPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.1),
          bodyLarge: TextStyle(
              color: lightTextPrimary, fontSize: 15, letterSpacing: -0.1),
          bodyMedium: TextStyle(
              color: lightTextSecondary, fontSize: 14, letterSpacing: -0.1),
          bodySmall:
              TextStyle(color: lightTextHint, fontSize: 12, letterSpacing: 0),
        ),
      );
}

/// 统一 SnackBar 扩展 — 自动避开底部导航栏
extension SnackBarX on BuildContext {
  static const double _navBarClearance = 88; // 底栏 + 间距

  void showSnack(
    String message, {
    Color? backgroundColor,
    Duration duration = const Duration(seconds: 2),
  }) {
    ScaffoldMessenger.of(this).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: backgroundColor,
      duration: duration,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, _navBarClearance),
    ));
  }
}
