import 'package:flutter/material.dart';

/// 屏幕适配工具类
/// 基于设计稿 393x852 (iPhone 15) 做比例缩放
/// Android 增强：边缘到边、导航栏高度、手势安全区
class Responsive {
  static double _screenWidth = 393;
  static double _screenHeight = 852;
  static double _statusBarHeight = 0;
  static double _bottomPadding = 0;
  static double _navigationBarHeight = 0;

  static void init(BuildContext context) {
    final mq = MediaQuery.of(context);
    final viewPadding = mq.viewPadding;
    final viewInsets = mq.viewInsets;

    _screenWidth = mq.size.width;
    _screenHeight = mq.size.height;
    _statusBarHeight = viewPadding.top;
    _bottomPadding = viewPadding.bottom;

    // Android 导航栏高度
    _navigationBarHeight = (viewPadding.bottom - viewInsets.bottom).clamp(0, 64);
  }

  /// 屏幕宽度
  static double get width => _screenWidth;
  /// 屏幕高度
  static double get height => _screenHeight;
  /// 状态栏高度
  static double get statusBar => _statusBarHeight;
  /// 底部安全区
  static double get bottomSafe => _bottomPadding;
  /// 导航栏高度（Android 虚拟按键栏）
  static double get navBarHeight => _navigationBarHeight;

  /// 是否小屏设备（宽度 < 360，如 SE、小屏安卓）
  static bool get isSmallScreen => _screenWidth < 360;
  /// 是否中等屏幕（360~414，大部分安卓）
  static bool get isMediumScreen => _screenWidth >= 360 && _screenWidth < 414;
  /// 是否大屏设备（>= 414，Plus/Max/折叠屏）
  static bool get isLargeScreen => _screenWidth >= 414;
  /// 是否平板（>= 600）
  static bool get isTablet => _screenWidth >= 600;
  /// 是否折叠屏（宽度在 600~700 之间，或宽高比接近 1:1）
  static bool get isFoldable =>
      _screenWidth >= 600 &&
      _screenWidth <= 800 &&
      (_screenWidth / _screenHeight).abs() > 0.7;

  /// 是否横屏（宽度大于高度）
  static bool get isLandscape => _screenWidth > _screenHeight;

  /// 按宽度比例缩放（基于 393 设计稿）
  static double wp(double designPx) => designPx * _screenWidth / 393;

  /// 按高度比例缩放（基于 852 设计稿）
  static double hp(double designPx) => designPx * _screenHeight / 852;

  /// 字体缩放（限制在 0.85~1.15 范围，避免过大过小）
  static double sp(double designPx) {
    final scale = _screenWidth / 393;
    return designPx * scale.clamp(0.85, 1.15);
  }

  /// 间距缩放
  static double gap(double designPx) => wp(designPx);

  /// 圆角缩放
  static double radius(double designPx) => wp(designPx);

  /// 图标大小缩放
  static double icon(double designPx) => wp(designPx);

  /// 安全区底部 padding（考虑 Android 导航栏和手势安全区）
  static double bottomPaddingWithNav(double extra) =>
      _bottomPadding + _navigationBarHeight + extra;
}
