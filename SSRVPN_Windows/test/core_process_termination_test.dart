import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';

void main() {
  test('graceful core exit does not send SIGKILL', () async {
    final process = _FakeProcess(
      onKill: (signal, exit) {
        if (signal == ProcessSignal.sigterm) exit.complete(0);
      },
    );

    expect(
      await terminateCoreProcess(
        process,
        gracefulTimeout: const Duration(milliseconds: 10),
        forcedTimeout: const Duration(milliseconds: 10),
      ),
      isTrue,
    );
    expect(process.signals, [ProcessSignal.sigterm]);
  });

  test('SIGTERM timeout waits for the forced exit', () async {
    final process = _FakeProcess(
      onKill: (signal, exit) {
        if (signal == ProcessSignal.sigkill) exit.complete(1);
      },
    );

    expect(
      await terminateCoreProcess(
        process,
        gracefulTimeout: const Duration(milliseconds: 1),
        forcedTimeout: const Duration(milliseconds: 10),
      ),
      isTrue,
    );
    expect(
      process.signals,
      [ProcessSignal.sigterm, ProcessSignal.sigkill],
    );
  });

  test('a core that survives SIGKILL is reported as still running', () async {
    final process = _FakeProcess();

    expect(
      await terminateCoreProcess(
        process,
        gracefulTimeout: const Duration(milliseconds: 1),
        forcedTimeout: const Duration(milliseconds: 1),
      ),
      isFalse,
    );
    expect(
      process.signals,
      [ProcessSignal.sigterm, ProcessSignal.sigkill],
    );
  });
}

class _FakeProcess implements Process {
  _FakeProcess({this.onKill});

  final void Function(ProcessSignal, Completer<int>)? onKill;
  final Completer<int> _exit = Completer<int>();
  final List<ProcessSignal> signals = [];

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    onKill?.call(signal, _exit);
    return true;
  }

  @override
  int get pid => 42;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();
}
