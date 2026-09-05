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

/// One undo record covers JSON/YAML and an optional preferred-node rename.
/// Deleting it commits all stores; an earlier crash restores them at startup.
extension _SubscriptionTransaction on _SubscriptionPersistence {
  File? get _transactionFile => _cacheDir == null
      ? null
      : File('$_cacheDir/${SubscriptionUndoRecord.fileName}');

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
    try {
      final result = await operation();
      await _commitDiskTransaction();
      return result;
    } catch (error, stack) {
      if (_transactionCommitted) rethrow;
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
        if (_nodePreferenceRename != null) {
          Error.throwWithStackTrace(
              StateError('首选节点恢复失败，请恢复存储权限后重试；订阅恢复记录已保留'), stack);
        }
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      _transactionSnapshot = null;
      _nodePreferenceRename = null;
      _publishPreference = null;
      final committed = _transactionCommitted;
      _transactionCommitted = false;
      final notify = _notificationPending;
      _notificationPending = false;
      if (committed && notify) notifyListeners();
    }
  }

  Future<void> _commitDiskTransaction() async {
    if (_transactionCommitted) return;
    final journal = _transactionFile;
    if (journal != null && await journal.exists()) await journal.delete();
    _transactionCommitted = true;
    // Publish both stores in one synchronous turn. No reader may combine a
    // staged preference with the old subscription snapshot.
    _transactionSnapshot = null;
    _publishPreference?.call();
  }

  Future<void> _prepareDiskTransaction() async {
    final journal = _transactionFile;
    if (!_transactionActive || journal == null || await journal.exists()) {
      return;
    }
    final previous = <String, String?>{};
    for (final name in SubscriptionUndoRecord.stateFiles) {
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
        journal,
        jsonEncode({
          'version': _nodePreferenceRename == null ? 1 : 2,
          'files': previous,
          if (_nodePreferenceRename != null)
            'preference': _nodePreferenceRename!.toJson(),
        }));
  }

  Future<void> _recoverDiskTransaction() async {
    final journal = _transactionFile;
    if (journal == null) return;
    final record = await SubscriptionUndoRecord.read(journal);
    if (record == null) return;
    final preference = record.preference;
    if (preference != null) {
      final preferences = _nodePreferences;
      if (preferences == null) throw StateError('首选节点恢复服务尚未初始化');
      await preferences.recoverNodePreference(preference);
    }
    for (final name in SubscriptionUndoRecord.stateFiles) {
      final file = File('$_cacheDir/$name');
      final content = record.files[name];
      if (content == null) {
        if (await file.exists()) await file.delete();
      } else {
        await writeStringAtomically(file, content);
      }
    }
    await journal.delete();
  }
}
