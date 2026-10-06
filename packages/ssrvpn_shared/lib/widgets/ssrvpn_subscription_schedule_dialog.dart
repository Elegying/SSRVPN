import 'ssrvpn_subscription_time_picker.dart';
import 'package:flutter/material.dart';
import '../models/subscription_update_schedule.dart';
import '../services/subscription_service_base.dart';
import 'ssrvpn_glass_dialog_route.dart';
import 'ssrvpn_app_surface.dart';

Future<void> showSubscriptionScheduleDialog(
        BuildContext context, SubscriptionServiceBase service) =>
    showSsrvpnGlassDialog<void>(
        context: context, builder: (_) => _ScheduleDialog(service: service));

class _ScheduleDialog extends StatefulWidget {
  const _ScheduleDialog({required this.service});
  final SubscriptionServiceBase service;
  @override
  State<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<_ScheduleDialog> {
  late Set<String> _ids;
  late Set<int> _days;
  late bool _weekly;
  late TimeOfDay _time;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final plan = widget.service.autoUpdater.schedule;
    _ids = {...?plan?.subscriptionIds};
    _days = {...?plan?.weekdays};
    _weekly = _days.isNotEmpty;
    _time = TimeOfDay(hour: plan?.hour ?? 9, minute: plan?.minute ?? 0);
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_ids.isNotEmpty && _weekly && _days.isEmpty) {
      setState(() => _error = '请选择至少一个星期');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.autoUpdater.save(SubscriptionUpdateSchedule(
          subscriptionIds: _ids,
          hour: _time.hour,
          minute: _time.minute,
          weekdays: _weekly ? _days : {},
          createdAt: DateTime.now()));
      if (mounted) dismissSsrvpnDialog<void>(context);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，选择已保留，请检查存储权限后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_saving,
      child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.all(24),
          child: SsrvpnModalGlassPanel(
              padding: const EdgeInsets.all(20),
              child: Material(
                  type: MaterialType.transparency,
                  child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxWidth: 480,
                          maxHeight: (MediaQuery.sizeOf(context).height - 96)
                              .clamp(180, 720)),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('自动更新订阅',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        Flexible(
                            child: SingleChildScrollView(
                                child: AnimatedBuilder(
                                    animation: widget.service,
                                    builder: (context, _) {
                                      final subs = widget.service.autoUpdater
                                          .remoteSubscriptions;
                                      return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            const Text(
                                                '勾选需要更新的订阅；全部取消即可关闭自动更新。'),
                                            const SizedBox(height: 8),
                                            if (subs.isEmpty)
                                              const Padding(
                                                  padding: EdgeInsets.symmetric(
                                                      vertical: 16),
                                                  child: Text(
                                                      '暂无可自动更新的订阅，请先添加订阅链接。单节点和手动添加的节点不参与自动更新。')),
                                            for (final sub in subs)
                                              CheckboxListTile(
                                                  key: ValueKey(
                                                      'schedule-sub-${sub.id}'),
                                                  contentPadding:
                                                      EdgeInsets.zero,
                                                  controlAffinity:
                                                      ListTileControlAffinity
                                                          .leading,
                                                  title: Text(sub.name),
                                                  subtitle: !sub.enabled
                                                      ? const Text(
                                                          '当前已停用，启用后按计划更新')
                                                      : null,
                                                  value: _ids.contains(sub.id),
                                                  onChanged: _saving
                                                      ? null
                                                      : (checked) =>
                                                          setState(() {
                                                            if (checked ==
                                                                true) {
                                                              _ids.add(sub.id);
                                                            } else {
                                                              _ids.remove(
                                                                  sub.id);
                                                            }
                                                          })),
                                            const Divider(),
                                            DropdownButtonFormField<bool>(
                                                initialValue: _weekly,
                                                decoration:
                                                    const InputDecoration(
                                                        labelText: '更新频率'),
                                                items: const [
                                                  DropdownMenuItem(
                                                      value: false,
                                                      child: Text('每天')),
                                                  DropdownMenuItem(
                                                      value: true,
                                                      child: Text('每周'))
                                                ],
                                                onChanged: _saving
                                                    ? null
                                                    : (v) => setState(() =>
                                                        _weekly = v ?? false)),
                                            if (_weekly)
                                              Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(vertical: 8),
                                                  child: Wrap(
                                                      spacing: 6,
                                                      runSpacing: 6,
                                                      children: [
                                                        for (var day = 1;
                                                            day <= 7;
                                                            day++)
                                                          FilterChip(
                                                              label: Text(
                                                                  '周${'一二三四五六日'[day - 1]}'),
                                                              selected: _days
                                                                  .contains(
                                                                      day),
                                                              onSelected:
                                                                  _saving
                                                                      ? null
                                                                      : (selected) =>
                                                                          setState(
                                                                              () {
                                                                            if (selected) {
                                                                              _days.add(day);
                                                                            } else {
                                                                              _days.remove(day);
                                                                            }
                                                                          }))
                                                      ])),
                                            ListTile(
                                                contentPadding: EdgeInsets.zero,
                                                title: const Text('更新时间'),
                                                trailing: Text(
                                                    '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}'),
                                                onTap: _saving
                                                    ? null
                                                    : () async {
                                                        final time =
                                                            await showSubscriptionTimePicker(
                                                                context, _time);
                                                        if (time != null &&
                                                            mounted) {
                                                          setState(() =>
                                                              _time = time);
                                                        }
                                                      }),
                                            const Text(
                                                '按设备本地时间执行。应用运行时自动更新；退出或系统暂停期间错过的计划，下次运行时补一次。失败来源保留原数据，可在订阅页手动重试。',
                                                style: TextStyle(
                                                    fontSize: 12, height: 1.5)),
                                            if (_error != null)
                                              Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          top: 8),
                                                  child: Semantics(
                                                      liveRegion: true,
                                                      child: Text(_error!,
                                                          style: TextStyle(
                                                              color: Theme.of(
                                                                      context)
                                                                  .colorScheme
                                                                  .error)))),
                                          ]);
                                    }))),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(
                              child: TextButton(
                                  onPressed: _saving
                                      ? null
                                      : () =>
                                          dismissSsrvpnDialog<void>(context),
                                  child: const Text('取消'))),
                          Expanded(
                              child: FilledButton(
                                  onPressed: _saving ? null : _save,
                                  child: Text(_saving ? '保存中…' : '保存')))
                        ]),
                      ]))))));
}

class SubscriptionScheduleTile extends StatefulWidget {
  const SubscriptionScheduleTile({super.key, required this.service});
  final SubscriptionServiceBase service;
  @override
  State<SubscriptionScheduleTile> createState() => _ScheduleTileState();
}

class _ScheduleTileState extends State<SubscriptionScheduleTile> {
  bool _open = false;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.service.autoUpdater,
      builder: (context, _) {
        final updater = widget.service.autoUpdater;
        final plan = updater.schedule;
        final summary = plan == null
            ? '未开启'
            : '${plan.summary} · ${plan.subscriptionIds.intersection(updater.remoteSubscriptions.map((s) => s.id).toSet()).length} 个订阅';
        return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.update),
            title: const Text('自动更新订阅'),
            subtitle: Text([
              summary,
              if (updater.lastResult != null) updater.lastResult!
            ].join('\n')),
            trailing: const Icon(Icons.chevron_right),
            onTap: _open
                ? null
                : () async {
                    setState(() => _open = true);
                    try {
                      await showSubscriptionScheduleDialog(
                          context, widget.service);
                    } finally {
                      if (mounted) setState(() => _open = false);
                    }
                  });
      });
}
