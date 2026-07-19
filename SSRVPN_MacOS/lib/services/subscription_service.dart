import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

/// macOS 订阅管理服务
///
/// 继承 [SubscriptionServiceBase] 共享逻辑，仅实现 macOS 特有的 HTTP 拉取策略：
/// - 先尝试 DirectFetcher 直连通道
/// - 降级到 dart:io HttpClient（带重试）
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
  Future<String?> fetchSubscription(
    String url, {
    int maxRetries = 3,
    SubscriptionRefreshControl? control,
  }) async {
    return fetchDesktopSubscription(
      url,
      allowDirectFetch: Platform.isMacOS,
      maxRetries: maxRetries,
      control: control,
    );
  }

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance.reset();
  }
}
