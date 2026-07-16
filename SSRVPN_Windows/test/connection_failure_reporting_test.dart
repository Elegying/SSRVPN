import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/screens/home_screen.dart';
import 'package:ssrvpn_windows/startup/startup_logger.dart';

final class _DesktopDirectoryOverride extends IOOverrides {
  _DesktopDirectoryOverride(this.desktop);

  final Directory desktop;

  @override
  Directory createDirectory(String path) {
    if (path.toLowerCase().endsWith(
          '${Platform.pathSeparator}desktop'.toLowerCase(),
        )) {
      return desktop;
    }
    return super.createDirectory(path);
  }
}

void main() {
  test('expected connection refusal writes only a warning', () async {
    final root = await Directory.systemTemp.createTemp(
      'ssrvpn_connection_failure_reporting_test_',
    );
    addTearDown(() => root.delete(recursive: true));

    final desktop = await Directory('${root.path}/Desktop').create();
    final crashDirectory = Directory('${root.path}/crashes');
    final startupLog = File('${root.path}/startup.log');
    await StartupLogger.init(verbose: false, fileOverride: startupLog);
    await CrashReporter.init(crashDirectory.path);

    final overrides = _DesktopDirectoryOverride(desktop);
    IOOverrides.runWithIOOverrides(
      () => recordDesktopConnectionFailure(
        'Connection failed: TUN 模式需要以管理员身份运行 SSRVPN',
        error: StateError('expected refusal'),
        stack: StackTrace.current,
        expected: true,
      ),
      overrides,
    );

    expect(desktop.listSync(), isEmpty);
    expect(await CrashReporter.pendingReports(), isEmpty);
    expect(await startupLog.readAsString(), contains('[WARN]'));

    IOOverrides.runWithIOOverrides(
      () => recordDesktopConnectionFailure('Connection failed'),
      overrides,
    );

    expect(
      desktop.listSync().whereType<File>(),
      hasLength(1),
    );
    expect(await CrashReporter.pendingReports(), hasLength(1));

    IOOverrides.runWithIOOverrides(
      () => recordDesktopConnectionFailure(
        'Connection threw',
        error: StateError('unexpected failure'),
        stack: StackTrace.current,
      ),
      overrides,
    );

    expect(
      desktop.listSync().whereType<File>(),
      hasLength(1),
    );
    expect(await CrashReporter.pendingReports(), hasLength(2));
  });
}
