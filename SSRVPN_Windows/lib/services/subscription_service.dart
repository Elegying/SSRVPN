import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/utils/async_lazy.dart';

/// Windows 订阅管理服务
///
/// 继承 [SubscriptionServiceBase] 共享逻辑，桌面端优先尝试 DirectFetcher
/// 直连通道，再降级到 dart:io HttpClient（带重试）。
class SubscriptionService extends SubscriptionServiceBase {
  static final _instance = AsyncLazy<SubscriptionService>();

  SubscriptionService._();

  static Future<SubscriptionService> getInstance(String cacheDir) {
    return _instance.get(() async {
      final service = SubscriptionService._();
      await service.init(cacheDir);
      return service;
    });
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
  }

  @override
  Future<String?> fetchSubscription(String url, {int maxRetries = 3}) async {
    return fetchDesktopSubscription(
      url,
      allowDirectFetch: Platform.isWindows,
      maxRetries: maxRetries,
    );
  }

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance.reset();
  }
}
