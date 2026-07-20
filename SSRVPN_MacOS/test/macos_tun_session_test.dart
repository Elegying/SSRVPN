import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/services/macos_tun_session.dart';

void main() {
  test('system authorization starts one TUN session and stop removes request',
      () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_test_');
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    String? executable;
    List<String>? arguments;
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (path, args) async {
        executable = path;
        arguments = args;
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {
            if (!authorizationExit.isCompleted) authorizationExit.complete(0);
          },
        );
      },
    );

    expect(await session.start(), isTrue);
    expect(executable, '/usr/bin/osascript');
    expect(arguments, hasLength(2));
    expect(arguments!.first, '-e');
    expect(arguments!.last, contains('with administrator privileges'));
    expect(arguments!.last, contains(runner.path));
    expect(arguments!.last, contains('--app-pid'));
    expect(arguments!.last, contains('123 2>&1'));
    expect(arguments!.last, contains('/var/run/ssrvpn-tun-launch-'));
    expect(arguments!.last, contains('/usr/bin/shasum -a 256'));
    expect(
      arguments!.last,
      contains(
        'b42eccaede42bdb9d254d5b7399491235c95366316feeac1751d7b1f6f4eacff',
      ),
    );
    expect(arguments!.last, isNot(contains('/usr/bin/nohup')));
    expect(await File(session.requestPath).exists(), isTrue);

    authorizationExit.complete(0);
    await session.stop();
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('stop reports a privileged DNS restoration failure', () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_stop_dns_failure_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final authorizationExit = Completer<int>();
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        await status.writeAsString('starting\n', flush: true);
        return TunAuthorizationHandle(
          exitCode: authorizationExit.future,
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isTrue);
    await status.writeAsString('error:dns\n', flush: true);
    authorizationExit.complete(1);

    await expectLater(session.stop(), throwsA(isA<StateError>()));
    expect(session.lastError, contains('DNS'));
    expect(await File(session.requestPath).readAsString(), '123\n');
  });

  test('startup DNS recovery is skipped without a stale TUN request', () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_no_recovery_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    var launched = false;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/tmp/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/missing.sh',
      appPid: 123,
      authorizationLauncher: (_, __) async {
        launched = true;
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await session.recoverStaleDnsIfNeeded(), isTrue);
    expect(launched, isFalse);
  });

  test('startup DNS recovery uses the trusted recovery-only runner mode',
      () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_recovery_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    final request = File('${dataDir.path}/.tun-session-request')
      ..writeAsStringSync('777\n');
    String? executable;
    List<String>? arguments;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      appPid: 123,
      authorizationLauncher: (path, args) async {
        executable = path;
        arguments = args;
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await session.recoverStaleDnsIfNeeded(), isTrue);
    expect(executable, '/usr/bin/osascript');
    expect(arguments, hasLength(2));
    expect(
      arguments!.last,
      contains(r'--recover-dns --app-pid \"$app_pid\"'),
    );
    expect(arguments!.last, contains(' 123 2>&1'));
    expect(arguments!.last, contains('/usr/bin/shasum -a 256'));
    expect(
      arguments!.last,
      contains(
        'b42eccaede42bdb9d254d5b7399491235c95366316feeac1751d7b1f6f4eacff',
      ),
    );
    expect(await request.exists(), isFalse);
  });

  test('startup DNS recovery also detects the supported legacy data directory',
      () async {
    final home = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_legacy_recovery_',
    );
    addTearDown(() => home.delete(recursive: true));
    final support = Directory('${home.path}/Library/Application Support');
    final currentDataDir = Directory(
      '${support.path}/com.ssrvpn.ssrvpnClient/SSRVPN',
    )..createSync(recursive: true);
    final legacyDataDir = Directory('${support.path}/SSRVPN')
      ..createSync(recursive: true);
    final runner = _writeTunAssets(currentDataDir);
    final legacyRequest = File('${legacyDataDir.path}/.tun-session-request')
      ..writeAsStringSync('777\n');
    var launched = false;
    final session = MacosTunSession(
      dataDir: currentDataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      appPid: 123,
      authorizationLauncher: (_, __) async {
        launched = true;
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await File(session.requestPath).exists(), isFalse);
    expect(await session.recoverStaleDnsIfNeeded(), isTrue);
    expect(launched, isTrue);
    expect(await legacyRequest.exists(), isFalse);
  });

  test('failed startup DNS recovery preserves the stale TUN request', () async {
    final dataDir = await Directory.systemTemp.createTemp(
      'ssrvpn_tun_recovery_failure_',
    );
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    final request = File('${dataDir.path}/.tun-session-request')
      ..writeAsStringSync('777\n');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      appPid: 123,
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(1),
        terminate: () {},
      ),
    );

    expect(await session.recoverStaleDnsIfNeeded(), isFalse);
    expect(session.lastError, contains('DNS'));
    expect(await request.exists(), isTrue);
  });

  test('cancelled authorization removes the pending TUN request', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_cancel_');
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final status = File('${dataDir.path}/status');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(1),
        terminate: () {},
      ),
    );

    expect(await session.start(), isFalse);
    expect(session.lastError, 'TUN 模式需要管理员授权，已取消');
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('interrupt cancels pending authorization without releasing its exit',
      () async {
    final dataDir =
        await Directory.systemTemp.createTemp('ssrvpn_tun_interrupt_');
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final authorizationStarted = Completer<void>();
    final neverExits = Completer<int>();
    var terminated = false;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: '${dataDir.path}/status',
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        authorizationStarted.complete();
        return TunAuthorizationHandle(
          exitCode: neverExits.future,
          terminate: () => terminated = true,
        );
      },
    );

    final starting = session.start();
    await authorizationStarted.future.timeout(const Duration(seconds: 1));
    expect(await File(session.requestPath).exists(), isTrue);

    session.interruptPendingStart();

    expect(
      await starting.timeout(const Duration(seconds: 1)),
      isFalse,
    );
    expect(terminated, isTrue);
    expect(session.lastError, 'TUN 连接已取消');
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('interrupt racing authorization return still terminates its handle',
      () async {
    final dataDir =
        await Directory.systemTemp.createTemp('ssrvpn_tun_launch_race_');
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final neverExits = Completer<int>();
    var terminated = false;
    late final MacosTunSession session;
    session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: '${dataDir.path}/status',
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        scheduleMicrotask(session.interruptPendingStart);
        return TunAuthorizationHandle(
          exitCode: neverExits.future,
          terminate: () => terminated = true,
        );
      },
    );

    expect(
      await session.start().timeout(const Duration(seconds: 1)),
      isFalse,
    );
    expect(terminated, isTrue);
    expect(session.lastError, 'TUN 连接已取消');
    expect(await File(session.requestPath).exists(), isFalse);
  });

  test('TUN refuses to authorize before the app is installed', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_path_');
    addTearDown(() => dataDir.delete(recursive: true));
    var invoked = false;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/tmp/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/missing.sh',
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async {
        invoked = true;
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isFalse);
    expect(session.lastError, contains('Applications'));
    expect(invoked, isFalse);
  });

  test('TUN startup status reports a categorized core failure', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_status_');
    addTearDown(() => dataDir.delete(recursive: true));
    final status = File('${dataDir.path}/status')
      ..writeAsStringSync('error:tun\n');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/runner.sh',
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(0),
        terminate: () {},
      ),
    );

    expect(await session.startupState(), MacosTunStartupState.failed);
    expect(session.lastError, contains('TUN 网卡或路由'));
  });

  test('TUN startup status reports a categorized DNS failure', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_dns_');
    addTearDown(() => dataDir.delete(recursive: true));
    final status = File('${dataDir.path}/status')
      ..writeAsStringSync('error:dns\n');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/runner.sh',
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(0),
        terminate: () {},
      ),
    );

    expect(await session.startupState(), MacosTunStartupState.failed);
    expect(session.lastError, contains('DNS'));
  });

  test('TUN startup status reports a stale privileged session', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_stale_');
    addTearDown(() => dataDir.delete(recursive: true));
    final status = File('${dataDir.path}/status')
      ..writeAsStringSync('error:stale\n');
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/runner.sh',
      statusPath: status.path,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(0),
        terminate: () {},
      ),
    );

    expect(await session.startupState(), MacosTunStartupState.failed);
    expect(session.lastError, contains('重启 Mac'));
  });

  test('TUN startup status ignores linked and malformed status files',
      () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_status_');
    addTearDown(() => dataDir.delete(recursive: true));
    final target = File('${dataDir.path}/target')
      ..writeAsStringSync('error:tun\n');
    final statusPath = '${dataDir.path}/status';
    await Link(statusPath).create(target.path);
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: '${dataDir.path}/runner.sh',
      statusPath: statusPath,
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: en0\n', ''),
      authorizationLauncher: (_, __) async => TunAuthorizationHandle(
        exitCode: Future<int>.value(0),
        terminate: () {},
      ),
    );

    expect(await session.startupState(), MacosTunStartupState.pending);
    expect(session.lastError, isNull);

    await Link(statusPath).delete();
    await File(statusPath).writeAsString('not-a-valid-status\n');
    expect(await session.startupState(), MacosTunStartupState.pending);
  });

  test('TUN refuses to start while another VPN owns the default route',
      () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_route_');
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir, runnerName: 'runner.sh');
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    var launched = false;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      statusPath: '${dataDir.path}/status',
      appPid: 123,
      routeProbe: (_, __) async =>
          ProcessResult(1, 0, '  interface: utun4\n', ''),
      authorizationLauncher: (_, __) async {
        launched = true;
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isFalse);
    expect(session.lastError, contains('其他 VPN'));
    expect(launched, isFalse);
  });

  test('TUN checks the IPv6 default route for another VPN', () async {
    final dataDir = await Directory.systemTemp.createTemp('ssrvpn_tun_route6_');
    addTearDown(() => dataDir.delete(recursive: true));
    final runner = _writeTunAssets(dataDir);
    File('${dataDir.path}/config.yaml').writeAsStringSync('proxies: []\n');
    final probes = <List<String>>[];
    var launched = false;
    final session = MacosTunSession(
      dataDir: dataDir.path,
      resolvedExecutable: '/Applications/SSRVPN.app/Contents/MacOS/SSRVPN',
      runnerPath: runner.path,
      appPid: 123,
      routeProbe: (_, arguments) async {
        probes.add(arguments);
        final interface = arguments.contains('-inet6') ? 'utun7' : 'en0';
        return ProcessResult(1, 0, '  interface: $interface\n', '');
      },
      authorizationLauncher: (_, __) async {
        launched = true;
        return TunAuthorizationHandle(
          exitCode: Future<int>.value(0),
          terminate: () {},
        );
      },
    );

    expect(await session.start(), isFalse);
    expect(session.lastError, contains('其他 VPN'));
    expect(probes, contains(equals(['-n', 'get', '-inet6', 'default'])));
    expect(launched, isFalse);
  });
}

File _writeTunAssets(
  Directory directory, {
  String runnerName = 'macos_tun_runner.sh',
}) {
  File('${directory.path}/AtlasCore.gz').writeAsBytesSync([1, 2, 3]);
  File('${directory.path}/AtlasCore-source.txt').writeAsStringSync('test\n');
  return File('${directory.path}/$runnerName')
    ..writeAsStringSync('#!/bin/bash\n');
}
