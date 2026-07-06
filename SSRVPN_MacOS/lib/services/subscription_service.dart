import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

/// macOS 订阅管理服务
///
/// 继承 [SubscriptionServiceBase] 共享逻辑，仅实现 macOS 特有的 HTTP 拉取策略：
/// - 先尝试 DirectFetcher 直连通道
/// - 降级到 dart:io HttpClient（带重试）
class SubscriptionService extends SubscriptionServiceBase {
  static SubscriptionService? _instance;

  SubscriptionService._();

  static Future<SubscriptionService> getInstance(String cacheDir) async {
    if (_instance == null) {
      _instance = SubscriptionService._();
      await _instance!.init(cacheDir);
    }
    return _instance!;
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
  }

  @override
  Future<String?> fetchSubscription(String url, {int maxRetries = 3}) async {
    return fetchDesktopSubscription(
      url,
      allowDirectFetch: Platform.isMacOS,
      maxRetries: maxRetries,
    );
  }

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance = null;
  }
}
