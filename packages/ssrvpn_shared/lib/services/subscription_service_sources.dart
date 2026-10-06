part of 'subscription_service_base.dart';

final _usageResponseKey = Object();

extension _SubscriptionSources on SubscriptionServiceBase {
  Future<String?> _fetchSourceContent(
      Subscription sub, SubscriptionRefreshControl control) async {
    if (!sub.refreshViaProxy) {
      return fetchSubscription(sub.url, control: control);
    }
    final response = await SubscriptionProxyFetcher.fetch(sub.url,
        proxyPort: () => connectedProxyPort?.call(),
        control: control,
        maxBytes: maxSubscriptionResponseBytes);
    control.throwIfStopped();
    recordSubscriptionResponseHeaders(sub.url, response.headers);
    return response.body;
  }

  Future<String> _fetchValidatedSource(
      Subscription sub, SubscriptionRefreshControl control) async {
    if (!isSingleNodeLink(sub.url)) SubscriptionUrlPolicy.parse(sub.url);
    Map<String, String> responseHeaders = {};
    final content = isSingleNodeLink(sub.url)
        ? _validatedLocalYaml(sub.url)
        : await runZoned(() => control.wait(_fetchSourceContent(sub, control)),
            zoneValues: {
                _usageResponseKey: (Map<String, String> headers) {
                  responseHeaders = headers;
                }
              });
    control.throwIfStopped();
    final yaml = content == null
        ? null
        : await SubscriptionProcessing.normalize(content, control);
    if (yaml == null || yaml.isEmpty) {
      throw const FormatException('返回内容为空或无法识别');
    }
    recordSubscriptionResponseHeaders(sub.url, responseHeaders);
    final validated = await SubscriptionProcessing.mergeAndParse(
      [yaml],
      [_sourceNameForFetchedSubscription(sub)],
      control,
      proxySourceKey: SubscriptionServiceBase.proxySourceKey,
      standaloneGroupName: SubscriptionServiceBase.standaloneGroupName,
    );
    if (validated.parsed.nodes.isEmpty) {
      throw const FormatException('订阅不包含可运行节点');
    }
    // Validation may allocate temporary collision suffixes. Keep the source's
    // original names so the final merge can match identities against its cache.
    sub.usage = SubscriptionUsagePolicy.allows(sub.url)
        ? SubscriptionUsage.fromHeaders(responseHeaders, now: DateTime.now())
        : null;
    return yaml;
  }

  Future<Map<String, String>> _cachedSourceYamls(
    SubscriptionRefreshControl control,
  ) =>
      SubscriptionProcessing.extractSources(
        _rawYaml,
        {
          for (final sub in _subscriptions)
            if (sub.enabled) sub.id: sourceNameForSubscription(sub)
        },
        control,
        localSources: {
          for (final sub in _subscriptions)
            if (sub.enabled && isSingleNodeLink(sub.url))
              sub.id: normalizeSubscriptionContent(sub.url)!,
        },
      );
  Future<MergedSubscriptionResult> _mergeSourceYamls(
    Map<String, String> sources,
    SubscriptionRefreshControl control, {
    Set<Subscription> refreshed = const {},
    String? restoredNames,
  }) async {
    final active = _subscriptions
        .where(
          (sub) => sub.enabled && sources.containsKey(sub.id),
        )
        .toList();
    final result = await SubscriptionProcessing.mergeAndParse(
      [
        for (final sub in active) sources[sub.id]!,
        if (sources[''] != null) sources['']!
      ],
      [
        for (final sub in active)
          refreshed.contains(sub)
              ? _sourceNameForFetchedSubscription(sub)
              : sourceNameForSubscription(sub),
        if (sources[''] != null) '历史缓存'
      ],
      control,
      proxySourceKey: SubscriptionServiceBase.proxySourceKey,
      standaloneGroupName: SubscriptionServiceBase.standaloneGroupName,
      sourceIds: [
        for (final sub in active) sub.id,
        if (sources[''] != null) ''
      ],
      previousYaml: _rawYaml,
      restoredNames: [
        for (final sub in _subscriptions)
          if (!sub.enabled &&
              sub.disabledNamesTrusted &&
              sub.disabledSourceYaml != null)
            sub.disabledSourceYaml!,
        if (restoredNames != null) restoredNames,
      ],
    );
    return result.yaml.isEmpty
        ? MergedSubscriptionResult(
            yaml: 'proxies: []\n',
            parsed: result.parsed,
            runtimeText: result.runtimeText,
          )
        : result;
  }
}
