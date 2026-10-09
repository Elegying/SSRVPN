import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_theme_icon.dart';

import '../services/recent_tasks_service.dart';

class RecentTasksVisibilityTile extends StatefulWidget {
  const RecentTasksVisibilityTile({super.key});

  @override
  State<RecentTasksVisibilityTile> createState() =>
      _RecentTasksVisibilityTileState();
}

class _RecentTasksVisibilityTileState extends State<RecentTasksVisibilityTile>
    with WidgetsBindingObserver {
  final _service = const RecentTasksService();
  bool? _enabled;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_update());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_update());
  }

  Future<void> _update([bool? enabled]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final actual = enabled == null
          ? await _service.read()
          : await _service.setEnabled(enabled);
      if (mounted) setState(() => _enabled = actual);
    } catch (_) {
      bool? actual;
      if (enabled != null) {
        try {
          actual = await _service.read();
        } catch (_) {
          // An unknown platform result must not appear as a saved preference.
        }
      }
      if (mounted) {
        setState(() {
          _enabled = actual;
          _error = enabled == null ? '无法读取系统设置，请重试。' : '设置未能完成，请重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('hide-from-recents'),
            contentPadding: EdgeInsets.zero,
            secondary: const SsrvpnThemeIcon('settings',
                fallback: Icons.visibility_off_outlined),
            title: const Text('隐藏后台'),
            subtitle: const Text(
                '从系统最近任务列表隐藏，减少误清理。可从桌面图标或 VPN 通知返回；仍可能被系统强制停止或省电策略清理。'),
            value: _enabled ?? false,
            onChanged: _busy || _enabled == null
                ? null
                : (value) => unawaited(_update(value)),
          ),
          if (_busy)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child:
                  Semantics(liveRegion: true, child: const Text('正在同步系统设置…')),
            ),
          if (_error != null)
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(liveRegion: true, child: Text(_error!)),
              TextButton(
                  onPressed: _busy ? null : () => unawaited(_update()),
                  child: const Text('重试')),
            ]),
        ],
      );
}
