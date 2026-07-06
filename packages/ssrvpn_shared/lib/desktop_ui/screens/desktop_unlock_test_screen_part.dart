part of desktop_unlock_test_screen;

class UnlockTestScreen extends StatefulWidget {
  const UnlockTestScreen({super.key});

  @override
  State<UnlockTestScreen> createState() => _UnlockTestScreenState();
}

class _UnlockTestScreenState extends State<UnlockTestScreen> {
  final UnlockTestService _service = UnlockTestService();
  List<UnlockTestResult> _items = List.of(UnlockTestService.defaultItems);
  bool _isTestingAll = false;
  final Set<String> _testingIds = {};
  String _activeCategory = 'all';

  static const _categories = [
    ('all', '全部', Icons.apps_rounded),
    ('streaming', '流媒体', Icons.play_circle_outline_rounded),
    ('ai', 'AI 服务', Icons.smart_toy_outlined),
    ('other', '其他', Icons.more_horiz_rounded),
  ];

  List<UnlockTestResult> get _filtered => _activeCategory == 'all'
      ? _items
      : _items.where((i) => i.category == _activeCategory).toList();

  int _countByCategory(String cat) =>
      _items.where((i) => i.category == cat).length;
  int _countUnlocked(String cat) => _items
      .where((i) => i.isUnlocked && (cat == 'all' || i.category == cat))
      .length;
  int _countBlocked(String cat) => _items
      .where((i) => i.isBlocked && (cat == 'all' || i.category == cat))
      .length;

  Future<void> _testAll() async {
    if (_isTestingAll) return;
    final clashService = context.read<ClashService>();
    if (!_ensureConnected(clashService)) return;

    setState(() {
      _isTestingAll = true;
      _testingIds.clear();
      _testingIds.addAll(_items.map((item) => item.id));
      _items = _items
          .map((item) => item.copyWith(status: 'Testing', clearDetail: true))
          .toList();
    });

    final proxyPort = clashService.runtimeProxyPort;
    final results = await _service.checkAll(proxyPort: proxyPort);
    if (!mounted) return;
    setState(() {
      _items = _mergeResults(_items, results);
      _testingIds.clear();
      _isTestingAll = false;
    });
  }

  Future<void> _testOne(UnlockTestResult item) async {
    if (_testingIds.contains(item.id)) return;
    final clashService = context.read<ClashService>();
    if (!_ensureConnected(clashService)) return;

    setState(() {
      _testingIds.add(item.id);
      _items = _items
          .map((entry) => entry.id == item.id
              ? entry.copyWith(status: 'Testing', clearDetail: true)
              : entry)
          .toList();
    });

    final result = await _service.checkOne(
        id: item.id, proxyPort: clashService.runtimeProxyPort);
    if (!mounted) return;
    setState(() {
      _items = _mergeResults(_items, [result]);
      _testingIds.remove(item.id);
    });
  }

  bool _ensureConnected(ClashService clashService) {
    if (clashService.isRunning) return true;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: EdgeInsets.fromLTRB(16, 0, 16, 16),
      content: Text('请先连接 VPN 后再进行解锁测试'),
    ));
    return false;
  }

  List<UnlockTestResult> _mergeResults(
    List<UnlockTestResult> current,
    List<UnlockTestResult> results,
  ) {
    final byId = {for (final result in results) result.id: result};
    return current.map((item) => byId[item.id] ?? item).toList();
  }

  Future<void> _openOfficialUrl(UnlockTestResult item) {
    return UpdateService.openExternalUrl(item.officialUrl);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subColor =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;
    final clashService = context.read<ClashService>();
    final settings = context.watch<SettingsService>().settings;
    final proxyPort = clashService.isRunning
        ? clashService.runtimeProxyPort
        : settings.proxyPort;
    final hasAnyResult = _items.any((i) => i.status != 'Unknown');

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 6),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [AppTheme.primary, AppTheme.accentColor]),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.fact_check_rounded,
                        color: Colors.white, size: 19),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('解锁测试',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: textColor)),
                        const SizedBox(height: 2),
                        Text('流媒体 · AI 服务 · 开发工具 可用性检测',
                            style: TextStyle(fontSize: 12, color: subColor)),
                      ],
                    ),
                  ),
                  _HeaderActionButton(
                    icon: _isTestingAll
                        ? Icons.hourglass_top_rounded
                        : Icons.playlist_play_rounded,
                    label: _isTestingAll ? '测试中' : '全部测试',
                    enabled: !_isTestingAll,
                    onTap: _testAll,
                  ),
                ],
              ),
            ),
            // ── Connect info ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
              child: _InfoStrip(
                  isDark: isDark,
                  connected: clashService.isRunning,
                  proxyPort: proxyPort),
            ),
            // ── Category tabs ──
            if (hasAnyResult) _buildCategoryTabs(isDark),
            // ── Summary bar ──
            if (hasAnyResult) _buildSummaryBar(isDark),
            // ── Unlock items ──
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 22),
                itemCount: _filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = _filtered[index];
                  return _UnlockListItem(
                    item: item,
                    isTesting: _testingIds.contains(item.id),
                    isDark: isDark,
                    textColor: textColor,
                    subColor: subColor,
                    onOpen: () => _openOfficialUrl(item),
                    onTest: () => _testOne(item),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryTabs(bool isDark) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Row(
        children: _categories.map((cat) {
          final (id, label, icon) = cat;
          final isActive = _activeCategory == id;
          final count = id == 'all' ? _items.length : _countByCategory(id);
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => setState(() => _activeCategory = id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isActive
                      ? AppTheme.primary.withValues(alpha: 0.12)
                      : (isDark ? AppTheme.card : AppTheme.lightBg),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isActive
                        ? AppTheme.primary.withValues(alpha: 0.3)
                        : AppTheme.border,
                    width: 0.5,
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon,
                      size: 14,
                      color:
                          isActive ? AppTheme.primary : AppTheme.textTertiary),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isActive
                              ? AppTheme.primary
                              : AppTheme.textSecondary)),
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppTheme.primary.withValues(alpha: 0.15)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('$count',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: isActive
                                ? AppTheme.primary
                                : AppTheme.textTertiary)),
                  ),
                ]),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSummaryBar(bool isDark) {
    final unlocked = _countUnlocked('all');
    final blocked = _countBlocked('all');
    final total = _items.where((i) => i.status != 'Unknown').length;
    if (total == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 2, 24, 2),
      child: Row(
        children: [
          _SummaryChip(label: '解锁 $unlocked', color: AppTheme.success),
          const SizedBox(width: 8),
          _SummaryChip(label: '阻止 $blocked', color: AppTheme.error),
          const SizedBox(width: 8),
          _SummaryChip(
            label: '失败 ${total - unlocked - blocked}',
            color: AppTheme.warning,
          ),
          const Spacer(),
          Text(
            '已测 $total/${_items.length}',
            style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────
// Shared widgets
// ────────────────────────────────────────

class _SummaryChip extends StatelessWidget {
  final String label;
  final Color color;
  const _SummaryChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

class _InfoStrip extends StatelessWidget {
  final bool isDark;
  final bool connected;
  final int proxyPort;
  const _InfoStrip(
      {required this.isDark, required this.connected, required this.proxyPort});

  @override
  Widget build(BuildContext context) {
    final color = connected ? AppTheme.success : AppTheme.warning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.08 : 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(children: [
        Icon(
            connected ? Icons.check_circle_outline_rounded : Icons.info_outline,
            color: color,
            size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            connected
                ? '当前走 127.0.0.1:$proxyPort 代理，检测结果对应当前节点'
                : '请先在主页连接 VPN',
            style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: color.withValues(alpha: 0.85),
                fontWeight: FontWeight.w600),
          ),
        ),
      ]),
    );
  }
}

class _UnlockListItem extends StatelessWidget {
  final UnlockTestResult item;
  final bool isTesting;
  final bool isDark;
  final Color textColor;
  final Color subColor;
  final Future<void> Function() onOpen;
  final VoidCallback onTest;

  const _UnlockListItem({
    required this.item,
    required this.isTesting,
    required this.isDark,
    required this.textColor,
    required this.subColor,
    required this.onOpen,
    required this.onTest,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = _statusColor(item);
    final statusLabel = _statusLabel(item);
    return Semantics(
      button: true,
      label: '打开 ${item.name} 官网',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            onOpen();
          },
          borderRadius: BorderRadius.circular(10),
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color:
                  isDark ? Colors.white.withValues(alpha: 0.04) : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color:
                    statusColor.withValues(alpha: item.isPending ? 0.18 : 0.35),
                width: 0.5,
              ),
              boxShadow: [
                if (!isDark)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    softWrap: true,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.18,
                      fontWeight: FontWeight.w800,
                      color: textColor,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox.square(
                  dimension: 32,
                  child: IconButton(
                    tooltip: isTesting ? '测试中' : '重新测试',
                    onPressed: isTesting ? null : onTest,
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    color: AppTheme.primary,
                    icon: isTesting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.primary,
                            ),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 44),
                  child: Text(
                    statusLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _statusColor(UnlockTestResult item) {
    if (isTesting || item.status == 'Testing') return AppTheme.primary;
    if (item.isUnlocked) return AppTheme.success;
    if (item.isPending) return subColor;
    return AppTheme.error;
  }

  String _statusLabel(UnlockTestResult item) {
    if (isTesting || item.status == 'Testing') return '测试中';
    if (item.isUnlocked) return '支持';
    if (item.isPending) return '待测试';
    return '不支持';
  }
}

class _HeaderActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  const _HeaderActionButton(
      {required this.icon,
      required this.label,
      required this.enabled,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.65,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: AppTheme.primary),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primary)),
          ]),
        ),
      ),
    );
  }
}
