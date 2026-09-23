part of 'subscription_service_base.dart';

mixin _SubscriptionPersistence on ChangeNotifier {
  List<Subscription> _subscriptions = [];
  String? _rawYaml;
  String? _cacheDir;
  int _revision = 0;
  int _displayRevision = 0;
  String _runtimeProxyText = '';
  _SubscriptionSnapshot? _transactionSnapshot;
  bool get _transactionActive => _transactionSnapshot != null;
  bool _notificationPending = false;
  bool _transactionCommitted = false;
  NodePreferenceStore? _nodePreferences;
  NodePreferenceRename? _nodePreferenceRename;
  void Function()? _publishPreference;
  final Map<String, String> _fetchedProfileNames = {};
  List<ProxyNode> _allNodes = [];
  List<ProxyGroup> _allGroups = [];
  NodeLatencyCache? _latencyCache;
  void parseYaml();

  @override
  void notifyListeners() {
    if (_transactionActive) {
      _notificationPending = true;
    } else {
      super.notifyListeners();
    }
  }

  // ── 持久化 ──

  Future<void> init(String cacheDir, {NodePreferenceStore? preferences}) async {
    _cacheDir = cacheDir;
    _nodePreferences = preferences;
    _latencyCache = NodeLatencyCache(
      directory: cacheDir,
      writeAtomically: writeStringAtomically,
    );
    await _latencyCache!.load();
    await loadFromDisk();
  }

  Future<void> loadFromDisk({SubscriptionRefreshControl? control}) async {
    final processingControl = control ??
        SubscriptionRefreshControl(
          timeout: SubscriptionServiceBase.defaultBatchRefreshTimeout,
        );
    _fetchedProfileNames.clear();
    if (_cacheDir == null) return;
    await _recoverDiskTransaction();

    final subsFile = File('$_cacheDir/subscriptions.json');
    if (await subsFile.exists()) {
      try {
        final content = utf8.decode(await subsFile.readAsBytes());
        final decoded = jsonDecode(content);
        if (decoded is! List) {
          throw const FormatException('subscriptions.json must be a list');
        }
        _subscriptions = decoded
            .map((e) => Subscription.fromJson(e as Map<String, dynamic>))
            .toList();
      } on FileSystemException {
        // Storage access failure is not evidence of corrupt subscription data.
        rethrow;
      } catch (e) {
        await backupBadFile(subsFile, 'subscriptions.json parse failed: $e');
        _subscriptions = [];
      }
    }

    final cacheFile = File('$_cacheDir/subscription_cache.yaml');
    if (await cacheFile.exists()) {
      try {
        if (await cacheFile.length() > BoundedYaml.maxInputBytes) {
          throw const YamlResourceLimitException(
            'subscription_cache.yaml exceeds the 20 MB limit',
          );
        }
        final content = utf8.decode(await cacheFile.readAsBytes());
        final parsed = await SubscriptionProcessing.parseSnapshot(
          content,
          processingControl,
          loadingCache: true,
        );
        processingControl.throwIfStopped();
        _rawYaml = content;
        _allNodes = parsed.parsed.nodes;
        _allGroups = parsed.parsed.groups;
        _latencyCache?.restore(_allNodes);
        if (parsed.runtimeText != null) _runtimeProxyText = parsed.runtimeText!;
        if (parsed.parseWarning != null) {
          AppLogger.warning(
              'SubscriptionService', 'YAML解析失败: ${parsed.parseWarning}');
        }
      } on FileSystemException {
        rethrow;
      } on SubscriptionRefreshCancelled {
        rethrow;
      } on SubscriptionRefreshDeadlineExceeded {
        rethrow;
      } catch (e) {
        await backupBadFile(
          cacheFile,
          'subscription_cache.yaml parse failed: $e',
        );
        _rawYaml = null;
        _allNodes = [];
        _allGroups = [];
      }
    }
  }

  Future<void> saveToDisk() async {
    if (_cacheDir == null) return;
    await _prepareDiskTransaction();
    final file = File('$_cacheDir/subscriptions.json');
    final jsonStr = jsonEncode(_subscriptions.map((s) => s.toJson()).toList());
    await writeStringAtomically(file, jsonStr);
  }

  Future<void> saveLatencyResults(List<ProxyNode> testedNodes) async {
    // A refresh may be staging a replacement while the UI still owns the last
    // committed snapshot. Accept only objects belonging to that visible state.
    final current = (_transactionSnapshot?.nodes ?? _allNodes).toSet();
    try {
      await _latencyCache?.record(testedNodes.where(current.contains));
    } catch (_) {
      AppLogger.warning('Latency', '延迟记录保存失败，保留之前的本地记录');
    }
  }

  Future<void> flushLatencyResults() async {
    await _latencyCache?.flush();
  }

  Future<void> cacheYaml(String yaml) async {
    if (_cacheDir == null) return;
    await _prepareDiskTransaction();
    final file = File('$_cacheDir/subscription_cache.yaml');
    await writeStringAtomically(file, yaml);
  }

  Future<void> _restoreCachedYaml(String? yaml) async {
    if (yaml != null) {
      await cacheYaml(yaml);
      return;
    }
    if (_cacheDir == null) return;
    final file = File('$_cacheDir/subscription_cache.yaml');
    if (await file.exists()) await file.delete();
  }

  Future<void> clearCachedNodes() async {
    if (_cacheDir != null) {
      await _prepareDiskTransaction();
      final cacheFile = File('$_cacheDir/subscription_cache.yaml');
      if (await cacheFile.exists()) await cacheFile.delete();
    }
    _rawYaml = null;
    _allNodes = [];
    _allGroups = [];
    _revision++;
    _displayRevision++;
    _runtimeProxyText = '';
  }

  Future<void> writeStringAtomically(File file, String content) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temp.writeAsString(content, flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> backupBadFile(File file, String reason) async {
    try {
      if (!await file.exists()) return;
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      final backup = File('${file.path}.bad-$stamp');
      await file.rename(backup.path);
      await File('${backup.path}.reason.txt').writeAsString(reason);
    } catch (_) {}
  }
}
