import 'dart:async';
import 'dart:io';

import '../models/proxy_group.dart';
import '../models/proxy_node.dart';
import '../models/subscription.dart';

abstract class SubscriptionScreenServicePort {
  List<Subscription> get subscriptions;
  List<ProxyNode> get allNodes;
  List<ProxyGroup> get allGroups;
  bool isSingleNodeLink(String input);
  String defaultSubscriptionName(String input);
  Future<Subscription> addSubscription(String name, String url);
  Future<String?> refreshAllSubscriptions();
  Future<void> removeSubscription(String id);
}

class CallbackSubscriptionScreenService
    implements SubscriptionScreenServicePort {
  const CallbackSubscriptionScreenService({
    required this.subscriptionsOf,
    required this.allNodesOf,
    required this.allGroupsOf,
    required this.isSingleNodeLinkOf,
    required this.defaultSubscriptionNameOf,
    required this.addSubscriptionWith,
    required this.refreshAllSubscriptionsWith,
    required this.removeSubscriptionWith,
  });

  final List<Subscription> Function() subscriptionsOf;
  final List<ProxyNode> Function() allNodesOf;
  final List<ProxyGroup> Function() allGroupsOf;
  final bool Function(String input) isSingleNodeLinkOf;
  final String Function(String input) defaultSubscriptionNameOf;
  final Future<Subscription> Function(String name, String url)
      addSubscriptionWith;
  final Future<String?> Function() refreshAllSubscriptionsWith;
  final Future<void> Function(String id) removeSubscriptionWith;

  @override
  List<Subscription> get subscriptions => subscriptionsOf();

  @override
  List<ProxyNode> get allNodes => allNodesOf();

  @override
  List<ProxyGroup> get allGroups => allGroupsOf();

  @override
  bool isSingleNodeLink(String input) => isSingleNodeLinkOf(input);

  @override
  String defaultSubscriptionName(String input) =>
      defaultSubscriptionNameOf(input);

  @override
  Future<Subscription> addSubscription(String name, String url) {
    return addSubscriptionWith(name, url);
  }

  @override
  Future<String?> refreshAllSubscriptions() {
    return refreshAllSubscriptionsWith();
  }

  @override
  Future<void> removeSubscription(String id) {
    return removeSubscriptionWith(id);
  }
}

enum SubscriptionAddStatus {
  emptyInput,
  duplicate,
  invalidUrl,
  singleNodeImported,
  singleNodeNoData,
  singleNodeImportFailed,
  subscriptionAdded,
  subscriptionNoData,
  refreshFailed,
  failed,
}

class SubscriptionAddResult {
  const SubscriptionAddResult({
    required this.status,
    this.nodeCount = 0,
    this.error,
    this.clearInput = false,
  });

  final SubscriptionAddStatus status;
  final int nodeCount;
  final Object? error;
  final bool clearInput;

  bool get isSuccess =>
      status == SubscriptionAddStatus.singleNodeImported ||
      status == SubscriptionAddStatus.subscriptionAdded;
}

class SubscriptionRefreshResult {
  const SubscriptionRefreshResult({
    required this.message,
    required this.success,
    this.networkErrorDetail,
  });

  final String message;
  final bool success;
  final String? networkErrorDetail;

  bool get shouldShowNetworkHelp => networkErrorDetail != null;
}

class SubscriptionDeleteResult {
  const SubscriptionDeleteResult({
    required this.removed,
    this.remainingRefreshFailed = false,
    this.stoppedClash = false,
    this.error,
  });

  final bool removed;
  final bool remainingRefreshFailed;
  final bool stoppedClash;
  final Object? error;
}

class SubscriptionScreenController {
  const SubscriptionScreenController({required this.subscriptionService});

  final SubscriptionScreenServicePort subscriptionService;

  Future<SubscriptionAddResult> addSubscription(String input) async {
    final url = input.trim();
    if (url.isEmpty) {
      return const SubscriptionAddResult(
        status: SubscriptionAddStatus.emptyInput,
      );
    }

    try {
      if (subscriptionService.subscriptions.any((sub) => sub.url == url)) {
        return const SubscriptionAddResult(
          status: SubscriptionAddStatus.duplicate,
        );
      }

      if (subscriptionService.isSingleNodeLink(url)) {
        return _addSingleNodeSubscription(url);
      }

      if (!_isValidHttpSubscriptionUrl(url)) {
        return const SubscriptionAddResult(
          status: SubscriptionAddStatus.invalidUrl,
        );
      }

      await subscriptionService.addSubscription(
        subscriptionService.defaultSubscriptionName(url),
        url,
      );
      return _refreshAfterAdd(
        successStatus: SubscriptionAddStatus.subscriptionAdded,
        noDataStatus: SubscriptionAddStatus.subscriptionNoData,
        failureStatus: SubscriptionAddStatus.refreshFailed,
      );
    } catch (e) {
      return SubscriptionAddResult(
        status: SubscriptionAddStatus.failed,
        error: e,
      );
    }
  }

  Future<SubscriptionRefreshResult> refreshAll() async {
    try {
      final yaml = await subscriptionService.refreshAllSubscriptions();
      if (yaml != null && yaml.isNotEmpty) {
        final nodeCount = subscriptionService.allNodes.length;
        final groupCount = subscriptionService.allGroups.length;
        return SubscriptionRefreshResult(
          message: '成功: 获取到 $nodeCount 个节点, $groupCount 个分组',
          success: true,
        );
      }
      return const SubscriptionRefreshResult(
        message: '刷新失败: 没有可用的订阅',
        success: false,
      );
    } on SocketException catch (e) {
      return SubscriptionRefreshResult(
        message: '刷新失败: 网络连接异常',
        success: false,
        networkErrorDetail: e.message,
      );
    } on TimeoutException {
      return const SubscriptionRefreshResult(
        message: '刷新失败: 连接超时',
        success: false,
        networkErrorDetail: '连接超时，请检查网络',
      );
    } catch (e) {
      final message = e.toString().replaceFirst('Exception: ', '');
      return SubscriptionRefreshResult(
        message: '刷新失败: $message',
        success: false,
        networkErrorDetail: _isNetworkErrorMessage(message) ? message : null,
      );
    }
  }

  Future<SubscriptionDeleteResult> deleteSubscription(
    String id, {
    required bool clashRunning,
    required Future<void> Function()? stopClash,
    bool continueAfterRefreshFailure = false,
  }) async {
    try {
      await subscriptionService.removeSubscription(id);
    } catch (e) {
      if (!continueAfterRefreshFailure) {
        return SubscriptionDeleteResult(removed: false, error: e);
      }
      return _deleteResultAfterOptionalStop(
        removed: true,
        remainingRefreshFailed: true,
        error: e,
        clashRunning: clashRunning,
        stopClash: stopClash,
      );
    }

    return _deleteResultAfterOptionalStop(
      removed: true,
      clashRunning: clashRunning,
      stopClash: stopClash,
    );
  }

  Future<SubscriptionAddResult> _addSingleNodeSubscription(String url) async {
    await subscriptionService.addSubscription(
      subscriptionService.defaultSubscriptionName(url),
      url,
    );
    return _refreshAfterAdd(
      successStatus: SubscriptionAddStatus.singleNodeImported,
      noDataStatus: SubscriptionAddStatus.singleNodeNoData,
      failureStatus: SubscriptionAddStatus.singleNodeImportFailed,
    );
  }

  Future<SubscriptionAddResult> _refreshAfterAdd({
    required SubscriptionAddStatus successStatus,
    required SubscriptionAddStatus noDataStatus,
    required SubscriptionAddStatus failureStatus,
  }) async {
    try {
      final yaml = await subscriptionService.refreshAllSubscriptions();
      if (yaml != null && yaml.isNotEmpty) {
        return SubscriptionAddResult(
          status: successStatus,
          nodeCount: subscriptionService.allNodes.length,
          clearInput: true,
        );
      }
      return SubscriptionAddResult(status: noDataStatus, clearInput: true);
    } catch (e) {
      return SubscriptionAddResult(
        status: failureStatus,
        error: e,
        clearInput: true,
      );
    }
  }

  Future<bool> _stopClashIfNeeded(
    bool clashRunning,
    Future<void> Function()? stopClash,
  ) async {
    if (subscriptionService.allNodes.isNotEmpty || !clashRunning) return false;
    if (stopClash == null) return false;
    await stopClash();
    return true;
  }

  Future<SubscriptionDeleteResult> _deleteResultAfterOptionalStop({
    required bool removed,
    required bool clashRunning,
    required Future<void> Function()? stopClash,
    bool remainingRefreshFailed = false,
    Object? error,
  }) async {
    try {
      final stopped = await _stopClashIfNeeded(clashRunning, stopClash);
      return SubscriptionDeleteResult(
        removed: removed,
        remainingRefreshFailed: remainingRefreshFailed,
        stoppedClash: stopped,
        error: error,
      );
    } catch (e) {
      return SubscriptionDeleteResult(
        removed: removed,
        remainingRefreshFailed: remainingRefreshFailed,
        stoppedClash: false,
        error: e,
      );
    }
  }

  bool _isValidHttpSubscriptionUrl(String url) {
    final parsedUri = Uri.tryParse(url);
    return parsedUri != null &&
        parsedUri.hasAuthority &&
        (parsedUri.scheme == 'http' || parsedUri.scheme == 'https');
  }

  bool _isNetworkErrorMessage(String message) {
    return message.contains('网络') ||
        message.contains('连接') ||
        message.contains('Socket') ||
        message.contains('超时') ||
        message.contains('DNS');
  }
}
