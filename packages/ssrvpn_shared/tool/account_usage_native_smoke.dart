// Run only in the disposable host described in CLIENT_USAGE_API_V1.md.
// This entry point never imports platform VPN services or production credentials.
// Eligibility is explicit so inspecting another app does not suspend this fixture.
// Real lifecycle wiring is covered separately by account_usage_identity_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const cert = String.fromEnvironment('SSRVPN_UAT_CERT');
  const key = String.fromEnvironment('SSRVPN_UAT_KEY');
  final context = SecurityContext()
    ..useCertificateChainBytes(base64Decode(cert))
    ..usePrivateKeyBytes(base64Decode(key));
  final trust = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(base64Decode(cert));
  final server =
      await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
  final state = _Scenario();
  server.listen((request) async {
    state.requests++;
    if (request.uri.path != '/api/v1/user/usage' ||
        request.headers.value('authorization') != 'Bearer synthetic-native') {
      request.response.statusCode = 401;
    } else if (state.fail) {
      request.response.statusCode = 503;
    } else {
      await state.firstResponse.future;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      request.response.write(jsonEncode({
        'apiVersion': 1,
        'data': {
          'scope': 'account',
          'usedBytes': state.large ? 9223372036854775807 : 0,
          'trafficLimitBytes': 268435456000,
          'onlineDevices': state.large ? 9223372036854775807 : 0,
          'deviceLimit': 3
        },
        'meta': {
          'serverTime': now,
          'trafficObservedAt': now - 2,
          'onlineObservedAt': now - 1,
          'expiresAt': now + 20,
          'complete': true
        }
      }));
    }
    await request.response.close();
  });
  final providers = AccountUsageProviders.fromJson(jsonEncode([
    {
      'id': 'native-smoke',
      'origin': 'https://localhost:${server.port}',
      'nodes': [
        {
          'id': 'fixture',
          'server': 'fixture.example.test',
          'port': 443,
          'protocol': 'hysteria2'
        }
      ]
    }
  ]));
  final controller = AccountUsageController(
      providers: providers,
      fetch: AccountUsageClient(createClient: () => HttpClient(context: trust))
          .fetch);
  runApp(_NativeSmoke(controller: controller, scenario: state, server: server));
}

class _Scenario {
  final firstResponse = Completer<void>();
  bool fail = false, large = false;
  int requests = 0;
}

class _NativeSmoke extends StatefulWidget {
  const _NativeSmoke(
      {required this.controller, required this.scenario, required this.server});
  final AccountUsageController controller;
  final _Scenario scenario;
  final HttpServer server;
  @override
  State<_NativeSmoke> createState() => _NativeSmokeState();
}

class _NativeSmokeState extends State<_NativeSmoke> {
  final capture = GlobalKey();
  bool eligible = false, connected = false;
  var navigation = 0;
  final reports = <Map<String, Object>>[];
  ProxyNode get node => ProxyNode(
      name: eligible ? '私家车-隔离模拟账号' : '普通节点-隔离模拟',
      type: 'hysteria2',
      server: 'fixture.example.test',
      port: 443,
      extra: {'password': 'synthetic-native'});
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(run()));
  }

  Future<void> check(String step, int count, {bool screenshot = false}) async {
    await WidgetsBinding.instance.endOfFrame;
    final cards = <RenderBox>[];
    final controls = <String, RenderBox>{};
    void inspect(Element element) {
      final key = element.widget.key;
      if (element.widget is Scrollable) {
        throw StateError('Home has a Scrollable');
      }
      if (key is ValueKey<String> &&
          key.value.startsWith('home-traffic-card-')) {
        cards.add(element.renderObject! as RenderBox);
      }
      if (key is ValueKey<String> &&
          const {
            'ssrvpn-power-button',
            'ssrvpn-current-node-card',
            'ssrvpn-about-button',
            'ssrvpn-tutorial-button',
            'ssrvpn-bottom-navigation',
            'home-connection-status'
          }.contains(key.value)) {
        controls[key.value] = element.renderObject! as RenderBox;
      }
      element.visitChildren(inspect);
    }

    final root = capture.currentContext! as Element;
    root.visitChildren(inspect);
    if (cards.length != count) {
      throw StateError('$step: expected $count cards, got ${cards.length}');
    }
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    for (final entry in controls.entries) {
      final rect = entry.value.localToGlobal(Offset.zero) & entry.value.size;
      if (rect.left < 0 ||
          rect.top < 0 ||
          rect.right > boundary.size.width ||
          rect.bottom > boundary.size.height) {
        throw StateError('$step: control outside viewport ${entry.key} $rect');
      }
    }
    final power = controls['ssrvpn-power-button']!;
    final status = controls['home-connection-status']!;
    if ((power.size.width - power.size.height).abs() > .1 ||
        ((power.localToGlobal(Offset.zero).dx + power.size.width / 2) -
                    (status.localToGlobal(Offset.zero).dx +
                        status.size.width / 2))
                .abs() >
            .1) {
      throw StateError('$step: connection group misaligned');
    }
    final rects =
        cards.map((box) => box.localToGlobal(Offset.zero) & box.size).toList();
    for (var i = 0; i < rects.length; i++) {
      final rect = rects[i];
      if (rect.top < 0 ||
          rect.left < 0 ||
          rect.bottom > boundary.size.height ||
          rect.right > boundary.size.width) {
        throw StateError('$step: card outside viewport $rect');
      }
      for (var j = i + 1; j < rects.length; j++) {
        if (rect.overlaps(rects[j])) throw StateError('$step: cards overlap');
      }
    }
    final output =
        Directory('${Directory.systemTemp.path}/ssrvpn-usage-native');
    await output.create(recursive: true);
    if (reports.isEmpty) debugPrint('USAGE_NATIVE_OUTPUT ${output.path}');
    if (screenshot) {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('${output.path}/$step.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    }
    reports.add({
      'step': step,
      'cards': count,
      'viewport': boundary.size.toString(),
      'requests': widget.scenario.requests
    });
    await File('${output.path}/report.json').writeAsString(jsonEncode(reports));
    debugPrint(
        'USAGE_NATIVE_CHECK platform=${Platform.operatingSystem} step=$step cards=$count');
  }

  Future<void> waitFor(bool Function() ready) async {
    final deadline = Stopwatch()..start();
    while (!ready()) {
      if (deadline.elapsed > const Duration(seconds: 50)) {
        throw StateError('Timed out waiting for fixture state');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<void> run() async {
    try {
      for (var attempt = 0; attempt < 100; attempt++) {
        final root = capture.currentContext?.findRenderObject();
        if (root is RenderBox &&
            root.hasSize &&
            root.size.width >= 200 &&
            root.size.height >= 300) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await WidgetsBinding.instance.endOfFrame;
      }
      await check('ordinary', 3);
      if (widget.scenario.requests != 0) {
        throw StateError('Ordinary node sent usage request');
      }
      setState(() => eligible = true);
      widget.controller.update(node: node, revision: null, active: true);
      await check('first-pending', 3);
      widget.scenario.firstResponse.complete();
      await waitFor(() => widget.controller.value != null);
      await check('valid-zero', 5, screenshot: true);
      setState(() => connected = true);
      await check('local-connected', 5);
      setState(() => connected = false);
      await check('local-disconnected', 5);
      widget.scenario.fail = true;
      await waitFor(() =>
          widget.controller.value == null && widget.scenario.requests >= 2);
      await check('refresh-failed', 3);
      widget.scenario.fail = false;
      widget.scenario.large = true;
      await waitFor(() => (widget.controller.value?.usedBytes ?? 0) > 0);
      await check('recovered-large', 5, screenshot: true);
      setState(() => eligible = false);
      widget.controller.update(node: node, revision: null, active: true);
      await check('ordinary-again', 3, screenshot: true);
      widget.controller.dispose();
      await widget.server.close(force: true);
      debugPrint(
          'USAGE_NATIVE_PASS platform=${Platform.operatingSystem} steps=${reports.length}');
      exit(0);
    } catch (error) {
      debugPrint('USAGE_NATIVE_FAIL ${error.runtimeType}');
      // Only fixture geometry/state is reported; no request/header dumps.
      debugPrint(error is StateError ? error.message : 'Native smoke failed');
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
      home: Scaffold(
          body: RepaintBoundary(
              key: capture,
              child: SsrvpnAppBackdrop(
                  child: Column(children: [
                Expanded(
                    child: SsrvpnHomeOverview(
                        isConnected: connected,
                        isConnecting: false,
                        selectedNode: node,
                        selectedLatency: 30,
                        selectedCountryCode: 'US',
                        onToggleConnection: () =>
                            setState(() => connected = !connected),
                        onOpenNodes: () {},
                        onShowAbout: () {},
                        onShowTutorial: () {},
                        onShowLogs: () {},
                        onRefreshPublicIp: () {},
                        bottomContent: AnimatedBuilder(
                            animation: widget.controller,
                            builder: (context, child) => SsrvpnHomeTrafficPanel(
                                active: true,
                                connected: connected,
                                accountUsage: widget.controller.value,
                                readSample: () async => null)))),
                SsrvpnBottomNavigation(
                    currentIndex: 0,
                    version: '模拟验证',
                    onTap: (_) => navigation++),
              ])))));
}
