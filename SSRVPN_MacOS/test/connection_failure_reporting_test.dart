import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/screens/home_screen.dart';
import 'package:ssrvpn_macos/startup/startup_logger.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  test('handled connection failures keep diagnostics without a crash prompt',
      () async {
    final root =
        await Directory.systemTemp.createTemp('ssrvpn_handled_failure_');
    addTearDown(() => root.delete(recursive: true));
    final log = File('${root.path}/startup.log');
    await StartupLogger.init(verbose: false, fileOverride: log);
    await CrashReporter.init('${root.path}/crashes');

    recordDesktopConnectionFailure(
        'Connection failed: SYSTEM_PROXY_APPLY_FAILED');
    recordDesktopConnectionFailure(
      'Connection cancelled: permission',
      expected: true,
    );
    recordDesktopConnectionFailure(
      'Connection threw',
      error: StateError('controlled failure'),
      stack: StackTrace.current,
    );

    expect(await CrashReporter.pendingReports(), isEmpty);
    final text = await log.readAsString();
    expect(text, contains('[ERROR]'));
    expect(text, contains('[WARN]'));
    expect(text, contains('SYSTEM_PROXY_APPLY_FAILED'));
    CrashReporter.recordSync('Uncaught error', StateError('fatal control'));
    expect(await CrashReporter.pendingReports(), hasLength(1));
  });
}
