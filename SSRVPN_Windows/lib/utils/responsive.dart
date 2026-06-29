import 'package:flutter/material.dart';

/// 屏幕适配工具类
/// 基于设计稿 393x852 (iPhone 15) 做比例缩放
class Responsive {
  static double _screenWidth = 393;
  static double _screenHeight = 852;
  static double _statusBarHeight = 0;
  static double _bottomPadding = 0;

  static void init(BuildContext context) {
    final mq = MediaQuery.of(context);
    _screenWidth = mq.size.width;
    _screenHeight = mq.size.height;
    _statusBarHeight = mq.padding.top;
    _bottomPadding = mq.padding.bottom;
  }

  /// 屏幕宽度
  static double get width => _screenWidth;

  /// 屏幕高度
  static double get height => _screenHeight;

  /// 状态栏高度
  static double get statusBar => _statusBarHeight;

  /// 底部安全区
  static double get bottomSafe => _bottomPadding;

  /// 是否小屏设备（宽度 < 360，如 SE、小屏安卓）
  static bool get isSmallScreen => _screenWidth < 360;

  /// 是否中等屏幕（360~414，大部分安卓）
  static bool get isMediumScreen => _screenWidth >= 360 && _screenWidth < 414;

  /// 是否大屏设备（>= 414，Plus/Max/折叠屏）
  static bool get isLargeScreen => _screenWidth >= 414;

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
}
