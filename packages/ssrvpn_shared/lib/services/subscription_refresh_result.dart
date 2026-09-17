enum SubscriptionBatchRefreshStatus { empty, success, partialSuccess }

class SubscriptionRefreshFailure {
  const SubscriptionRefreshFailure({
    required this.subscriptionName,
    required this.message,
    this.diagnosticCode,
  });

  final String subscriptionName;
  final String message;
  final String? diagnosticCode;

  String get detail => '$subscriptionName: $message';
  String get technicalDetail =>
      diagnosticCode == null ? detail : '$detail [$diagnosticCode]';
}

class SubscriptionBatchRefreshResult {
  const SubscriptionBatchRefreshResult({
    required this.status,
    required this.yaml,
    this.successfulSubscriptionNames = const [],
    this.successfulSubscriptionIds = const [],
    this.failures = const [],
  });

  final SubscriptionBatchRefreshStatus status;
  final String? yaml;
  final List<String> successfulSubscriptionNames;
  final List<String> successfulSubscriptionIds;
  final List<SubscriptionRefreshFailure> failures;

  bool get isPartialSuccess =>
      status == SubscriptionBatchRefreshStatus.partialSuccess;
}

class SubscriptionPartialRefreshException implements Exception {
  const SubscriptionPartialRefreshException(this.outcome);

  final SubscriptionBatchRefreshResult outcome;

  @override
  String toString() => '部分订阅刷新失败；成功来源已更新，失败来源保留已有节点:\n'
      '${outcome.failures.map((failure) => failure.detail).join('\n')}';
}

class SubscriptionBatchRefreshException implements Exception {
  SubscriptionBatchRefreshException(List<SubscriptionRefreshFailure> failures)
      : failures = List.unmodifiable(failures);

  final List<SubscriptionRefreshFailure> failures;

  @override
  String toString() => '所有订阅刷新失败:\n'
      '${failures.map((failure) => failure.detail).join('\n')}';
}
