import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'startup/startup_flags.dart';
import 'startup/startup_logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 解析启动参数（Android 通过 Intent extras 传入）
  final flags = StartupFlags.defaults();

  await StartupLogger.init(verbose: flags.verbose);
  StartupLogger.info('SSRVPN Android 启动');

  // 全局错误处理
  FlutterError.onError = (details) {
    StartupLogger.error('FlutterError', details.exception, details.stack);
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    StartupLogger.error('PlatformDispatcher error', error, stack);
    return true;
  };

  // Android 边缘到边显示
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
  ));

  // 启用边缘到边
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
  );

  runApp(SSRVpnApp(startupFlags: flags));
}
