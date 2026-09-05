part of 'subscription_service_base.dart';

typedef _SubscriptionSnapshot = ({
  String? yaml,
  List<ProxyNode> nodes,
  List<ProxyGroup> groups,
  List<Subscription> subscriptions,
  int revision,
  int displayRevision,
  String runtimeText,
  Map<String, String> names,
});

/// One undo record covers the existing JSON/YAML pair. Deleting it commits the
/// pair; a crash before that point restores both files before loading them.
extension _SubscriptionTransaction on _SubscriptionPersistence {
  File? get _transactionFile => _cacheDir == null
      ? null
      : File('$_cacheDir/subscription_transaction.json');

  Future<T> _runTransaction<T>(Future<T> Function() operation) async {
    await _recoverDiskTransaction();
    final subscriptions = List<Subscription>.of(_subscriptions);
    final states = {for (final sub in subscriptions) sub: sub.toJson()};
    // Readers keep using the last committed state, including while a failed
    // write is being rolled back. Notification deferral alone is not isolation.
    final snapshot = _transactionSnapshot = (
      yaml: _rawYaml,
      nodes: _allNodes,
      groups: _allGroups,
      subscriptions: states.values.map(Subscription.fromJson).toList(),
      revision: _revision,
      displayRevision: _displayRevision,
      runtimeText: _runtimeProxyText,
      names: Map<String, String>.of(_fetchedProfileNames),
    );
    var committed = false;
    try {
      final result = await operation();
      final journal = _transactionFile;
      if (journal != null && await journal.exists()) await journal.delete();
      committed = true;
      return result;
    } catch (error, stack) {
      _subscriptions = subscriptions;
      for (final entry in states.entries) {
        final saved = Subscription.fromJson(entry.value);
        entry.key
          ..name = saved.name
          ..url = saved.url
          ..lastUpdate = saved.lastUpdate
          ..enabled = saved.enabled
          ..autoUpdate = saved.autoUpdate;
      }
      _rawYaml = snapshot.yaml;
      _allNodes = snapshot.nodes;
      _allGroups = snapshot.groups;
      _revision = snapshot.revision;
      _displayRevision = snapshot.displayRevision;
      _runtimeProxyText = snapshot.runtimeText;
      _fetchedProfileNames
        ..clear()
        ..addAll(snapshot.names);
      try {
        await _recoverDiskTransaction();
      } catch (_) {
        // Keep the record. A later mutation cannot start until recovery works.
        try {
          AppLogger.warning('SubscriptionService', '订阅恢复未完成，已保留恢复记录');
        } catch (_) {}
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      _transactionSnapshot = null;
      final notify = _notificationPending;
      _notificationPending = false;
      if (committed && notify) notifyListeners();
    }
  }

  Future<void> _prepareDiskTransaction() async {
    final journal = _transactionFile;
    if (!_transactionActive || journal == null || await journal.exists()) {
      return;
    }
    final previous = <String, String?>{};
    for (final name in const [
      'subscriptions.json',
      'subscription_cache.yaml'
    ]) {
      final file = File('$_cacheDir/$name');
      if (await file.exists()) {
        if (await file.length() > BoundedYaml.maxInputBytes) {
          throw const FileSystemException('订阅状态超过恢复记录大小上限');
        }
        previous[name] = await file.readAsString();
      } else {
        previous[name] = null;
      }
    }
    await writeStringAtomically(
        journal, jsonEncode({'version': 1, 'files': previous}));
  }

  Future<void> _recoverDiskTransaction() async {
    final journal = _transactionFile;
    if (journal == null || !await journal.exists()) return;
    if (await journal.length() > BoundedYaml.maxInputBytes * 8) {
      throw const FileSystemException('订阅恢复记录超过大小上限');
    }
    final data = jsonDecode(await journal.readAsString());
    if (data is! Map || data['version'] != 1 || data['files'] is! Map) {
      throw const FormatException('订阅恢复记录无效');
    }
    final files = data['files'] as Map;
    const names = ['subscriptions.json', 'subscription_cache.yaml'];
    for (final name in names) {
      final content = files[name];
      if (!files.containsKey(name) ||
          (content != null && content is! String) ||
          (content is String &&
              utf8.encode(content).length > BoundedYaml.maxInputBytes)) {
        throw const FormatException('订阅恢复记录内容无效');
      }
    }
    for (final name in names) {
      final file = File('$_cacheDir/$name');
      final content = files[name] as String?;
      if (content == null) {
        if (await file.exists()) await file.delete();
      } else {
        await writeStringAtomically(file, content);
      }
    }
    await journal.delete();
  }
}
