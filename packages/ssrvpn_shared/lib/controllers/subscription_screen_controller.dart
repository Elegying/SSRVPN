import 'dart:async';
import 'dart:io';

import '../models/proxy_group.dart';
import '../models/proxy_node.dart';
import '../models/subscription.dart';
import '../services/subscription_service_base.dart';
import '../services/subscription_refresh_control.dart';
import '../utils/log_redactor.dart';
import '../utils/proxy_node_usage_policy.dart';
import '../utils/subscription_url_policy.dart';

abstract class SubscriptionScreenServicePort {
  List<Subscription> get subscriptions;
  List<ProxyNode> get allNodes;
  List<ProxyGroup> get allGroups;
  bool isSingleNodeLink(String input);
  String defaultSubscriptionName(String input);
  Future<Subscription> addSubscription(String name, String url);
  Future<SubscriptionBatchRefreshResult> refreshAllSubscriptionsDetailed({
    SubscriptionRefreshCancellation? cancellation,
    Duration timeout = SubscriptionServiceBase.defaultBatchRefreshTimeout,
  });
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
    required this.refreshAllSubscriptionsDetailedWith,
    required this.removeSubscriptionWith,
  });

  final List<Subscription> Function() subscriptionsOf;
  final List<ProxyNode> Function() allNodesOf;
  final List<ProxyGroup> Function() allGroupsOf;
  final bool Function(String input) isSingleNodeLinkOf;
  final String Function(String input) defaultSubscriptionNameOf;
  final Future<Subscription> Function(String name, String url)
      addSubscriptionWith;
  final Future<SubscriptionBatchRefreshResult> Function({
    SubscriptionRefreshCancellation? cancellation,
    Duration timeout,
  }) refreshAllSubscriptionsDetailedWith;
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
  Future<SubscriptionBatchRefreshResult> refreshAllSubscriptionsDetailed({
    SubscriptionRefreshCancellation? cancellation,
    Duration timeout = SubscriptionServiceBase.defaultBatchRefreshTimeout,
  }) {
    return refreshAllSubscriptionsDetailedWith(
      cancellation: cancellation,
      timeout: timeout,
    );
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

  static const int maxDisplayErrorCharacters = 512;

  String get displayError => _sanitizeRefreshDisplayText(
        error,
        maxCharacters: maxDisplayErrorCharacters,
      ).replaceFirst('Exception: ', '');

  bool get isSuccess =>
      status == SubscriptionAddStatus.singleNodeImported ||
      status == SubscriptionAddStatus.subscriptionAdded;
}

enum SubscriptionRefreshStatus { success, partialSuccess, cancelled, failure }

class SubscriptionRefreshResult {
  SubscriptionRefreshResult({
    required String message,
    required this.status,
    String? networkErrorDetail,
    List<String> failureDetails = const [],
  })  : message = _sanitizeRefreshDisplayText(
          message,
          maxCharacters: maxMessageCharacters,
        ),
        networkErrorDetail = networkErrorDetail == null
            ? null
            : _sanitizeRefreshDisplayText(
                networkErrorDetail,
                maxCharacters: maxNetworkErrorDetailCharacters,
              ),
        failureDetails = _sanitizeRefreshFailureDetails(failureDetails);

  static const int maxMessageCharacters = 1024;
  static const int maxNetworkErrorDetailCharacters = 1024;
  static const int maxFailureDetails = 20;
  static const int maxFailureDetailCharacters = 512;
  static const int maxFailureDetailsTotalCharacters = 4096;

  final String message;
  final SubscriptionRefreshStatus status;
  final String? networkErrorDetail;
  final List<String> failureDetails;

  bool get success => status == SubscriptionRefreshStatus.success;
  bool get isPartialSuccess =>
      status == SubscriptionRefreshStatus.partialSuccess;
  bool get shouldShowNetworkHelp => networkErrorDetail != null;
}

String _sanitizeRefreshDisplayText(
  Object? value, {
  required int maxCharacters,
}) {
  final safe = LogRedactor.sanitizeForDisplay(value);
  if (safe.length <= maxCharacters) return safe;
  if (maxCharacters <= 1) return '…'.substring(0, maxCharacters);

  var end = maxCharacters - 1;
  if (end < safe.length &&
      end > 0 &&
      _isHighSurrogate(safe.codeUnitAt(end - 1)) &&
      _isLowSurrogate(safe.codeUnitAt(end))) {
    end--;
  }
  return '${safe.substring(0, end)}…';
}

List<String> _sanitizeRefreshFailureDetails(List<String> details) {
  final safeDetails = <String>[];
  var totalCharacters = 0;
  for (final detail
      in details.take(SubscriptionRefreshResult.maxFailureDetails)) {
    final separatorCharacters = safeDetails.isEmpty ? 0 : 1;
    final remaining =
        SubscriptionRefreshResult.maxFailureDetailsTotalCharacters -
            totalCharacters -
            separatorCharacters;
    if (remaining <= 0) break;
    final itemLimit =
        remaining < SubscriptionRefreshResult.maxFailureDetailCharacters
            ? remaining
            : SubscriptionRefreshResult.maxFailureDetailCharacters;
    final safeDetail = _sanitizeRefreshDisplayText(
      detail,
      maxCharacters: itemLimit,
    );
    safeDetails.add(safeDetail);
    totalCharacters += separatorCharacters + safeDetail.length;
  }
  return List.unmodifiable(safeDetails);
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

class SubscriptionDeleteResult {
  const SubscriptionDeleteResult({
    required this.removed,
    this.stoppedClash = false,
    this.error,
  });

  final bool removed;
  final bool stoppedClash;
  final Object? error;

  static const int maxDisplayErrorCharacters = 512;

  String get displayError => _sanitizeRefreshDisplayText(
        error,
        maxCharacters: maxDisplayErrorCharacters,
      ).replaceFirst('Exception: ', '');
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

  Future<SubscriptionRefreshResult> refreshAll({
    SubscriptionRefreshCancellation? cancellation,
    Duration timeout = SubscriptionServiceBase.defaultBatchRefreshTimeout,
  }) async {
    try {
      final outcome = await subscriptionService.refreshAllSubscriptionsDetailed(
        cancellation: cancellation,
        timeout: timeout,
      );
      if (outcome.isPartialSuccess) {
        final failedNames = outcome.failures
            .map((failure) => failure.subscriptionName)
            .join('、');
        final retained =
            outcome.yaml?.isNotEmpty == true ? '已保留上次有效节点' : '当前没有可用的旧节点';
        return SubscriptionRefreshResult(
          message:
              '部分成功: 已获取 ${outcome.successfulSubscriptionNames.length} 个订阅，'
              '${outcome.failures.length} 个失败；$retained。失败项: $failedNames',
          status: SubscriptionRefreshStatus.partialSuccess,
          failureDetails:
              outcome.failures.map((failure) => failure.detail).toList(),
        );
      }
      final yaml = outcome.yaml;
      if (yaml != null && yaml.isNotEmpty) {
        final nodeCount = _runnableNodeCount();
        final groupCount = subscriptionService.allGroups.length;
        return SubscriptionRefreshResult(
          message: '成功: 获取到 $nodeCount 个节点, $groupCount 个分组',
          status: SubscriptionRefreshStatus.success,
        );
      }
      return SubscriptionRefreshResult(
        message: '刷新失败: 没有可用的订阅',
        status: SubscriptionRefreshStatus.failure,
      );
    } on SubscriptionRefreshCancelled {
      return SubscriptionRefreshResult(
        message: '刷新已取消',
        status: SubscriptionRefreshStatus.cancelled,
      );
    } on SubscriptionRefreshDeadlineExceeded catch (e) {
      return SubscriptionRefreshResult(
        message: '刷新失败: 已超过 ${e.timeout.inSeconds} 秒总时限，'
            '请重试或删除长期失效订阅',
        status: SubscriptionRefreshStatus.failure,
      );
    } on SocketException catch (e) {
      return SubscriptionRefreshResult(
        message: '刷新失败: 网络连接异常',
        status: SubscriptionRefreshStatus.failure,
        networkErrorDetail: e.message,
      );
    } on TimeoutException {
      return SubscriptionRefreshResult(
        message: '刷新失败: 连接超时',
        status: SubscriptionRefreshStatus.failure,
        networkErrorDetail: '连接超时，请检查网络',
      );
    } catch (e) {
      final message = e.toString().replaceFirst('Exception: ', '');
      return SubscriptionRefreshResult(
        message: '刷新失败: $message',
        status: SubscriptionRefreshStatus.failure,
        networkErrorDetail: _isNetworkErrorMessage(message) ? message : null,
      );
    }
  }

  Future<SubscriptionDeleteResult> deleteSubscription(
    String id, {
    required bool clashRunning,
    required Future<void> Function()? stopClash,
    Future<void> Function()? onNoRunnableNodes,
  }) async {
    try {
      await subscriptionService.removeSubscription(id);
    } catch (e) {
      return SubscriptionDeleteResult(removed: false, error: e);
    }

    return _deleteResultAfterOptionalStop(
      removed: true,
      clashRunning: clashRunning,
      stopClash: stopClash,
      onNoRunnableNodes: onNoRunnableNodes,
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
      final outcome =
          await subscriptionService.refreshAllSubscriptionsDetailed();
      if (outcome.isPartialSuccess) {
        return SubscriptionAddResult(
          status: failureStatus,
          error: SubscriptionPartialRefreshException(outcome),
          clearInput: true,
        );
      }
      final yaml = outcome.yaml;
      if (yaml != null && yaml.isNotEmpty) {
        return SubscriptionAddResult(
          status: successStatus,
          nodeCount: _runnableNodeCount(),
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
    if (_hasRunnableNodes() || !clashRunning) return false;
    if (stopClash == null) return false;
    await stopClash();
    return true;
  }

  int _runnableNodeCount() {
    return subscriptionService.allNodes
        .where(ProxyNodeUsagePolicy.isRunnableNode)
        .length;
  }

  bool _hasRunnableNodes() => _runnableNodeCount() > 0;

  Future<SubscriptionDeleteResult> _deleteResultAfterOptionalStop({
    required bool removed,
    required bool clashRunning,
    required Future<void> Function()? stopClash,
    Future<void> Function()? onNoRunnableNodes,
    Object? error,
  }) async {
    var stopped = false;
    Object? operationError = error;
    try {
      stopped = await _stopClashIfNeeded(clashRunning, stopClash);
    } catch (e) {
      operationError = e;
    }
    if (!_hasRunnableNodes()) {
      try {
        await onNoRunnableNodes?.call();
      } catch (e) {
        operationError ??= e;
      }
    }
    return SubscriptionDeleteResult(
      removed: removed,
      stoppedClash: stopped,
      error: operationError,
    );
  }

  bool _isValidHttpSubscriptionUrl(String url) {
    try {
      SubscriptionUrlPolicy.parse(url);
      return true;
    } on FormatException {
      return false;
    }
  }

  bool _isNetworkErrorMessage(String message) {
    return message.contains('网络') ||
        message.contains('连接') ||
        message.contains('Socket') ||
        message.contains('超时') ||
        message.contains('DNS');
  }
}
