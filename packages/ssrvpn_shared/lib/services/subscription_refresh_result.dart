enum SubscriptionBatchRefreshStatus { empty, success, partialSuccess }

class SubscriptionRefreshFailure {
  const SubscriptionRefreshFailure({
    required this.subscriptionName,
    required this.message,
  });

  final String subscriptionName;
  final String message;

  String get detail => '$subscriptionName: $message';
}

class SubscriptionBatchRefreshResult {
  const SubscriptionBatchRefreshResult({
    required this.status,
    required this.yaml,
    this.successfulSubscriptionNames = const [],
    this.failures = const [],
  });

  final SubscriptionBatchRefreshStatus status;
  final String? yaml;
  final List<String> successfulSubscriptionNames;
  final List<SubscriptionRefreshFailure> failures;

  bool get isPartialSuccess =>
      status == SubscriptionBatchRefreshStatus.partialSuccess;
}

class SubscriptionPartialRefreshException implements Exception {
  const SubscriptionPartialRefreshException(this.outcome);

  final SubscriptionBatchRefreshResult outcome;

  @override
  String toString() => '部分订阅刷新失败，已保留上次有效节点:\n'
      '${outcome.failures.map((failure) => failure.detail).join('\n')}';
}
