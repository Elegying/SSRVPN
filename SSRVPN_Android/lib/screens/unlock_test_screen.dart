import '../utils/responsive.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/clash_service.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import '../theme/app_theme.dart';
import '../widgets/liquid_glass.dart';

class UnlockTestScreen extends StatefulWidget {
  const UnlockTestScreen({super.key});

  @override
  State<UnlockTestScreen> createState() => _UnlockTestScreenState();
}

class _UnlockTestScreenState extends State<UnlockTestScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final UnlockTestService _service = UnlockTestService();
  List<UnlockTestResult> _items = List.of(UnlockTestService.defaultItems);
  bool _isTestingAll = false;
  UnlockTestCancellation? _allCancellation;
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

  int _countByCategory(String cat) => cat == 'all'
      ? _items.length
      : _items.where((i) => i.category == cat).length;

  Future<void> _testAll() async {
    if (_isTestingAll) {
      _allCancellation?.cancel();
      return;
    }
    final clashService = context.read<ClashService>();
    if (!_ensureConnected(clashService)) return;
    final cancellation = UnlockTestCancellation();
    final previousItems = List<UnlockTestResult>.of(_items);
    _allCancellation = cancellation;

    setState(() {
      _isTestingAll = true;
      _testingIds
        ..clear()
        ..addAll(_items.map((item) => item.id));
      _items = _items
          .map(
            (item) => item.copyWith(status: 'Testing', clearDetail: true),
          )
          .toList();
    });

    List<UnlockTestResult>? results;
    Object? failure;
    try {
      results = await _service.checkAll(
        proxyPort: clashService.runtimeProxyPort,
        cancellation: cancellation,
      );
    } on UnlockTestCancelled {
      // Keep the last completed evidence when the user cancels.
    } catch (error) {
      failure = error;
    }
    if (!mounted || !identical(_allCancellation, cancellation)) return;
    setState(() {
      _items = results == null ? previousItems : _mergeResults(_items, results);
      _testingIds.clear();
      _isTestingAll = false;
      _allCancellation = null;
    });
    if (failure != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('批量解锁测试未完成，请稍后重试')),
      );
    }
  }

  @override
  void dispose() {
    _allCancellation?.cancel();
    super.dispose();
  }

  Future<void> _testOne(UnlockTestResult item) async {
    if (_testingIds.contains(item.id)) return;
    final clashService = context.read<ClashService>();
    if (!_ensureConnected(clashService)) return;

    setState(() {
      _testingIds.add(item.id);
      _items = _items
          .map(
            (entry) => entry.id == item.id
                ? entry.copyWith(status: 'Testing', clearDetail: true)
                : entry,
          )
          .toList();
    });

    final result = await _service.checkOne(
      id: item.id,
      proxyPort: clashService.runtimeProxyPort,
    );
    if (!mounted) return;
    setState(() {
      _items = _mergeResults(_items, [result]);
      _testingIds.remove(item.id);
    });
  }

  bool _ensureConnected(ClashService clashService) {
    if (clashService.isRunning) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
        content: Text('请先连接 VPN 后再进行解锁测试'),
      ),
    );
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
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final subColor =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final clashService = context.read<ClashService>();
    final settings = context.watch<SettingsService>().settings;
    final proxyPort = clashService.isRunning
        ? clashService.runtimeProxyPort
        : settings.proxyPort;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(24, 18, 24, 10),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [AppTheme.primaryColor, AppTheme.accentColor],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.fact_check_rounded,
                      color: Colors.white,
                      size: 19,
                    ),
                  ),
                  SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '解锁测试',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Responsive.sp(18),
                            fontWeight: FontWeight.w800,
                            color: textColor,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '区分“明确支持”“仅可访问”和“无法判断”',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: Responsive.sp(12), color: subColor),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 8),
                  _HeaderActionButton(
                    icon: _isTestingAll
                        ? Icons.stop_circle_outlined
                        : Icons.playlist_play_rounded,
                    label: _isTestingAll ? '取消测试' : '全部测试',
                    enabled: true,
                    onTap: _testAll,
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 10),
              child: _InfoStrip(
                isDark: isDark,
                connected: clashService.isRunning,
                proxyPort: proxyPort,
              ),
            ),
            // 分类筛选栏
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: 24),
                itemCount: _categories.length,
                separatorBuilder: (_, __) => SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final (cat, label, icon) = _categories[index];
                  final selected = _activeCategory == cat;
                  return FilterChip(
                    showCheckmark: false,
                    avatar: Icon(icon,
                        size: 14,
                        color: selected ? Colors.white : AppTheme.primaryColor),
                    label: Text(
                      '$label (${_countByCategory(cat)})',
                      style: TextStyle(
                        fontSize: Responsive.sp(12),
                        color: selected ? Colors.white : null,
                      ),
                    ),
                    selected: selected,
                    selectedColor: AppTheme.primaryColor,
                    onSelected: (_) => setState(() => _activeCategory = cat),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.symmetric(horizontal: 4),
                  );
                },
              ),
            ),
            SizedBox(height: 4),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.fromLTRB(
                    24,
                    4,
                    24,
                    MediaQuery.of(context).padding.bottom +
                        LiquidGlassNavBar.height +
                        20),
                itemCount: _filtered.length,
                separatorBuilder: (_, __) => SizedBox(height: 8),
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
}

class _InfoStrip extends StatelessWidget {
  final bool isDark;
  final bool connected;
  final int proxyPort;

  const _InfoStrip({
    required this.isDark,
    required this.connected,
    required this.proxyPort,
  });

  @override
  Widget build(BuildContext context) {
    final color = connected ? AppTheme.successColor : AppTheme.warningColor;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: (isDark ? 16 : 20) / 255),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: color.withValues(alpha: (isDark ? 42 : 52) / 255)),
      ),
      child: Row(
        children: [
          Icon(
            connected ? Icons.check_circle_outline_rounded : Icons.info_outline,
            color: color,
            size: 18,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              connected
                  ? '当前走 127.0.0.1:$proxyPort；官网可访问不等于已解锁，详情会说明证据边界。'
                  : '请先在主页连接 VPN；未连接时测试请求不会发出。',
              style: TextStyle(
                fontSize: Responsive.sp(12),
                height: 1.35,
                color: color.withValues(alpha: 230 / 255),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
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
    final detail = [
      if (item.region?.isNotEmpty ?? false) '地区 ${item.region}',
      if (item.detail?.isNotEmpty ?? false) item.detail!,
    ].join(' · ');
    return Semantics(
      button: true,
      label: '打开 ${item.name} 官网，状态 ${item.displayStatusLabel}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            onOpen();
          },
          borderRadius: BorderRadius.circular(10),
          child: Container(
            constraints: const BoxConstraints(minHeight: 60),
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 6 / 255)
                  : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: statusColor.withValues(
                  alpha: (item.isPending ? 34 : 70) / 255,
                ),
              ),
              boxShadow: [
                if (!isDark)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 8 / 255),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: Responsive.sp(14),
                          height: 1.18,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                      if (detail.isNotEmpty) ...[
                        SizedBox(height: 3),
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Responsive.sp(10.5),
                            height: 1.25,
                            color: subColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: 10),
                SizedBox.square(
                  dimension: 32,
                  child: IconButton(
                    tooltip: isTesting ? '测试中' : '重新测试',
                    onPressed: isTesting ? null : onTest,
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    color: AppTheme.primaryColor,
                    icon: isTesting
                        ? SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.primaryColor,
                            ),
                          )
                        : Icon(Icons.refresh_rounded),
                  ),
                ),
                SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 44),
                  child: Text(
                    item.displayStatusLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: Responsive.sp(13),
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
    if (isTesting || item.status == 'Testing') return AppTheme.primaryColor;
    if (item.isSuccessful) return AppTheme.successColor;
    if (item.isReachable) return AppTheme.primaryColor;
    if (item.isPending) return subColor;
    if (item.isInconclusive || item.isFailed) return AppTheme.warningColor;
    return AppTheme.errorColor;
  }
}

class _HeaderActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _HeaderActionButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.65,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          height: 34,
          padding: EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppTheme.primaryColor.withValues(alpha: 20 / 255),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: AppTheme.primaryColor.withValues(alpha: 55 / 255)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: AppTheme.primaryColor),
              SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: Responsive.sp(12),
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
