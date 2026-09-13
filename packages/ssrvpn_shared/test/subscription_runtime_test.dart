import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

class _Core implements ClashServiceBase {
  @override
  bool isRunning = true;
  @override
  bool connectionDesired = true;
  final listeners = <void Function()>[];
  final requests = <Completer<String?>>[];
  @override
  void addStatusListener(void Function() listener) => listeners.add(listener);
  @override
  void removeStatusListener(void Function() listener) =>
      listeners.remove(listener);
  @override
  Future<String?> currentSelectedProxyName() {
    final request = Completer<String?>();
    requests.add(request);
    return request.future;
  }

  void emit() {
    for (final listener in List.of(listeners)) {
      listener();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
      'shared status rejects old replies, detaches swapped cores and survives lookup failure',
      (tester) async {
    final first = _Core();
    final second = _Core();
    Widget host(_Core core) => MaterialApp(
            home: SsrvpnSubscriptionRuntime(
          core: core,
          builder: (_, status, node) =>
              Text('${status.name}:${node ?? "unknown"}'),
        ));
    await tester.pumpWidget(host(first));
    first.emit();
    first.requests.last.complete('当前节点');
    await tester.pump();
    expect(find.text('connected:当前节点'), findsOneWidget);
    first.requests.first.complete('过期节点');
    await tester.pump();
    expect(find.text('connected:当前节点'), findsOneWidget);
    first.emit();
    await tester.pumpWidget(host(second));
    expect(first.listeners, isEmpty);
    first.requests.last.complete('旧核心节点');
    second.requests.last.completeError(StateError('unavailable'));
    await tester.pump();
    expect(find.text('connected:unknown'), findsOneWidget);
    second.isRunning = false;
    second.emit();
    await tester.pump();
    expect(find.text('connecting:unknown'), findsOneWidget);
    second.connectionDesired = false;
    second.emit();
    await tester.pump();
    expect(find.text('disconnected:unknown'), findsOneWidget);
    second.isRunning = true;
    second.emit();
    await tester.pumpWidget(const SizedBox());
    second.requests.last.complete('退出后返回');
    await tester.pump();
    expect(second.listeners, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
