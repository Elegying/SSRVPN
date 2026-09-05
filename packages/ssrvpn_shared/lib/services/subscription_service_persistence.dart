part of 'subscription_service_base.dart';

mixin _SubscriptionPersistence on ChangeNotifier {
  List<Subscription> _subscriptions = [];
  String? _rawYaml;
  String? _cacheDir;
  int _revision = 0;
  int _displayRevision = 0;
  String _runtimeProxyText = '';
  bool _transactionActive = false;
  bool _notificationPending = false;
  final Map<String, String> _fetchedProfileNames = {};
  List<ProxyNode> _allNodes = [];
  List<ProxyGroup> _allGroups = [];
  void parseYaml();

  @override
  void notifyListeners() {
    if (_transactionActive) {
      _notificationPending = true;
    } else {
      super.notifyListeners();
    }
  }

  void _acceptCache(String yaml, ParsedSubscription parsed) {
    final runtimeText = ClashConfigGenerator.buildProxiesText(yaml);
    if (runtimeText != _runtimeProxyText) {
      _revision++;
    } else {
      final previous = {for (final node in _allNodes) node.name: node};
      for (final node in parsed.nodes) {
        final old = previous[node.name];
        if (old == null) continue;
        node.latency = old.latency;
        node.lastLatencyTest = old.lastLatencyTest;
        node.isOnline = old.isOnline;
      }
    }
    if (yaml != _rawYaml) _displayRevision++;
    _runtimeProxyText = runtimeText;
    _rawYaml = yaml;
    _allNodes = parsed.nodes;
    _allGroups = parsed.groups;
  }
  // ── 持久化 ──

  Future<void> init(String cacheDir) async {
    _cacheDir = cacheDir;
    await loadFromDisk();
  }

  Future<void> loadFromDisk() async {
    _fetchedProfileNames.clear();
    if (_cacheDir == null) return;
    await _recoverDiskTransaction();

    final subsFile = File('$_cacheDir/subscriptions.json');
    if (await subsFile.exists()) {
      try {
        final content = await subsFile.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is! List) {
          throw const FormatException('subscriptions.json must be a list');
        }
        _subscriptions = decoded
            .map((e) => Subscription.fromJson(e as Map<String, dynamic>))
            .toList();
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
        final content = await cacheFile.readAsString();
        final parsed = BoundedYaml.load(content);
        if (parsed != null && parsed is! Map) {
          throw const FormatException(
            'subscription_cache.yaml must be a YAML map',
          );
        }
        _rawYaml = content;
        parseYaml();
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
    await temp.writeAsString(content, flush: true);
    await temp.rename(file.path);
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
