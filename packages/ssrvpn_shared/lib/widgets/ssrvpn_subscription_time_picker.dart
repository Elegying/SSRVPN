import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'ssrvpn_app_surface.dart';
import 'ssrvpn_glass_dialog_route.dart';

Future<TimeOfDay?> showSubscriptionTimePicker(
        BuildContext context, TimeOfDay initial) =>
    showSsrvpnGlassDialog<TimeOfDay>(
        context: context,
        builder: (_) => _SubscriptionTimePicker(initial: initial));

class _SubscriptionTimePicker extends StatefulWidget {
  const _SubscriptionTimePicker({required this.initial});
  final TimeOfDay initial;
  @override
  State<_SubscriptionTimePicker> createState() => _TimePickerState();
}

class _TimePickerState extends State<_SubscriptionTimePicker> {
  late int _hour = widget.initial.hour;
  late int _minute = widget.initial.minute;
  late final _hours = FixedExtentScrollController(initialItem: _hour);
  late final _minutes = FixedExtentScrollController(initialItem: _minute);

  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  Widget _wheel(String label, int count, FixedExtentScrollController controller,
          ValueChanged<int> onChanged) =>
      Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label),
        SizedBox(
            height: 160,
            child: CupertinoPicker(
                key: ValueKey('subscription-time-$label'),
                scrollController: controller,
                itemExtent: 40,
                onSelectedItemChanged: onChanged,
                children: [
                  for (var value = 0; value < count; value++)
                    Center(
                        child: Text(value.toString().padLeft(2, '0'),
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                                fontSize: 24,
                                color:
                                    Theme.of(context).colorScheme.onSurface)))
                ]))
      ]));

  @override
  Widget build(BuildContext context) => Dialog(
      backgroundColor: Colors.transparent,
      child: SsrvpnModalGlassPanel(
          padding: const EdgeInsets.all(20),
          child: Material(
              type: MaterialType.transparency,
              child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('更新时间',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Text(
                    '${_hour.toString().padLeft(2, '0')}:${_minute.toString().padLeft(2, '0')}',
                    key: const Key('subscription-time-preview'),
                    style: const TextStyle(fontSize: 28)),
                const SizedBox(height: 12),
                Row(children: [
                  _wheel('小时', 24, _hours,
                      (value) => setState(() => _hour = value)),
                  _wheel('分钟', 60, _minutes,
                      (value) => setState(() => _minute = value))
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                      child: TextButton(
                          onPressed: () =>
                              dismissSsrvpnDialog<TimeOfDay>(context),
                          child: const Text('取消'))),
                  Expanded(
                      child: FilledButton(
                          onPressed: () => dismissSsrvpnDialog(
                              context, TimeOfDay(hour: _hour, minute: _minute)),
                          child: const Text('确定')))
                ])
              ])))));
}
