import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/theme/app_theme.dart';
import 'package:ssrvpn_android/utils/responsive.dart';
import 'package:ssrvpn_android/widgets/home_node_list.dart';
import 'package:ssrvpn_android/widgets/node_list_tile.dart';
import 'package:ssrvpn_android/widgets/proxy_mode_selector.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  Widget host(
    Widget child, {
    ThemeMode themeMode = ThemeMode.light,
    Size size = const Size(600, 900),
  }) {
    return MaterialApp(
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Builder(
          builder: (context) {
            Responsive.init(context);
            return Scaffold(body: SizedBox.expand(child: child));
          },
        ),
      ),
    );
  }

  ProxyNode node(
    String name, {
    String type = 'ss',
    String server = 'example.com',
    int port = 8388,
    String group = '默认',
    int? latency,
  }) {
    return ProxyNode(
      name: name,
      type: type,
      server: server,
      port: port,
      group: group,
      latency: latency,
      extra: {
        'name': name,
        'type': type,
        'server': server,
        'port': port,
      },
    );
  }

  testWidgets('proxy mode selector changes only while enabled', (tester) async {
    final selections = <String>[];
    await tester.pumpWidget(
      host(
        Center(
          child: SizedBox(
            width: 360,
            child: ProxyModeSelector(
              isDark: false,
              settings: AppSettings(proxyMode: ProxyMode.rule),
              enabled: true,
              onChanged: selections.add,
            ),
          ),
        ),
      ),
    );

    expect(find.text('规则'), findsOneWidget);
    expect(find.text('全局'), findsOneWidget);
    await tester.tap(find.text('全局'));
    expect(selections, ['global']);

    await tester.pumpWidget(
      host(
        Center(
          child: SizedBox(
            width: 360,
            child: ProxyModeSelector(
              isDark: true,
              settings: AppSettings(proxyMode: ProxyMode.global),
              enabled: false,
              onChanged: selections.add,
            ),
          ),
        ),
        themeMode: ThemeMode.dark,
      ),
    );
    await tester.tap(find.text('规则'));
    expect(selections, ['global']);
  });

  testWidgets('node tile exposes identity, endpoint, latency and gestures',
      (tester) async {
    var taps = 0;
    var longPresses = 0;
    await tester.pumpWidget(
      host(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              NodeListTile(
                node: node(
                  'JP - Tokyo',
                  type: 'hysteria2',
                  server: '2001:db8::1',
                ),
                latency: 128,
                isTesting: false,
                isSelected: true,
                isTimeout: false,
                isConnected: true,
                onTestLatency: () {},
                onTap: () => taps++,
                onLongPress: () => longPresses++,
                textColor: Colors.black,
                subColor: Colors.black54,
                isDark: false,
              ),
              NodeListTile(
                node: node('Plain node', type: 'vmess'),
                latency: null,
                isTesting: false,
                isSelected: false,
                isTimeout: false,
                isConnected: true,
                onTestLatency: () => taps += 10,
                onTap: () => taps++,
                onLongPress: () => longPresses++,
                textColor: Colors.black,
                subColor: Colors.black54,
                isDark: false,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Tokyo'), findsOneWidget);
    expect(find.text('🇯🇵'), findsOneWidget);
    expect(find.text('[2001:db8::1]:8388'), findsOneWidget);
    expect(find.text('HYST'), findsOneWidget);
    expect(find.text('128ms'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('测速'), findsOneWidget);

    await tester.tap(find.text('Tokyo'));
    await tester.longPress(find.text('Tokyo'));
    await tester.tap(find.text('测速'));
    expect(taps, 11);
    expect(longPresses, 1);
  });

  testWidgets('timed out nodes cannot be selected but remain inspectable',
      (tester) async {
    var taps = 0;
    var longPresses = 0;
    await tester.pumpWidget(
      host(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              NodeListTile(
                node: node('US — Timeout', type: 'trojan'),
                latency: 65535,
                isTesting: false,
                isSelected: false,
                isTimeout: true,
                isConnected: true,
                onTestLatency: () {},
                onTap: () => taps++,
                onLongPress: () => longPresses++,
                textColor: Colors.white,
                subColor: Colors.white70,
                isDark: true,
              ),
              NodeListTile(
                node: node('Testing node'),
                latency: null,
                isTesting: true,
                isSelected: false,
                isTimeout: false,
                isConnected: true,
                onTestLatency: () {},
                onTap: () {},
                onLongPress: () {},
                textColor: Colors.white,
                subColor: Colors.white70,
                isDark: true,
              ),
              NodeListTile(
                node: node('Slow node'),
                latency: 800,
                isTesting: false,
                isSelected: false,
                isTimeout: false,
                isConnected: false,
                onTestLatency: () {},
                onTap: () {},
                onLongPress: () {},
                textColor: Colors.white,
                subColor: Colors.white70,
                isDark: true,
              ),
            ],
          ),
        ),
        themeMode: ThemeMode.dark,
      ),
    );

    expect(find.text('Timeout'), findsOneWidget);
    expect(find.text('超时'), findsOneWidget);
    expect(find.text('800ms'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Timeout'));
    await tester.longPress(find.text('Timeout'));
    expect(taps, 0);
    expect(longPresses, 1);
  });

  testWidgets('home node list distinguishes connecting and empty states',
      (tester) async {
    HomeNodeList buildList({required bool connecting}) {
      return HomeNodeList(
        nodes: const [],
        latencyController: HomeLatencyController(),
        expandedSubscriptionGroups: const {},
        selectedNode: null,
        testingNodeName: null,
        isConnecting: connecting,
        isBatchTesting: false,
        isConnected: false,
        textColor: Colors.black,
        subColor: Colors.black54,
        isDark: false,
        onTestAllLatency: () {},
        onTestLatency: (_) {},
        onSelectNode: (_) {},
        onLongPressNode: (_) {},
        onEditNode: (_) {},
        onToggleSubscriptionGroup: (_, __) {},
      );
    }

    await tester.pumpWidget(host(buildList(connecting: true)));
    expect(find.text('正在启动VPN核心...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(host(buildList(connecting: false)));
    expect(find.text('暂无节点'), findsOneWidget);
    expect(find.text('请先在订阅页面添加订阅链接'), findsOneWidget);
  });

  testWidgets('home node list groups subscriptions and forwards actions',
      (tester) async {
    final alpha = node('JP - Alpha Tokyo', group: '订阅 A');
    final beta = node('US - Beta Seattle', group: '订阅 B');
    final selected = <String>[];
    final held = <String>[];
    final tested = <String>[];
    final toggles = <String>[];
    var batchTests = 0;

    await tester.pumpWidget(
      host(
        HomeNodeList(
          nodes: [alpha, beta],
          latencyController: HomeLatencyController(
            latencies: {'JP - Alpha Tokyo': 88},
          ),
          expandedSubscriptionGroups: const {'订阅 A'},
          selectedNode: alpha,
          testingNodeName: null,
          isConnecting: false,
          isBatchTesting: false,
          isConnected: true,
          textColor: Colors.black,
          subColor: Colors.black54,
          isDark: false,
          onTestAllLatency: () => batchTests++,
          onTestLatency: (value) => tested.add(value.name),
          onSelectNode: (value) => selected.add(value.name),
          onLongPressNode: (value) => held.add(value.name),
          onEditNode: (_) {},
          onToggleSubscriptionGroup: (title, expanded) {
            toggles.add('$title:$expanded');
          },
        ),
      ),
    );

    expect(find.text('全部节点'), findsOneWidget);
    expect(find.text('订阅 A'), findsOneWidget);
    expect(find.text('订阅 B'), findsOneWidget);
    expect(find.text('Alpha Tokyo'), findsOneWidget);
    expect(find.text('Beta Seattle'), findsNothing);
    expect(find.text('88ms'), findsOneWidget);

    await tester.tap(find.text('测速'));
    await tester.tap(find.text('订阅 A'));
    await tester.tap(find.text('Alpha Tokyo'));
    await tester.longPress(find.text('Alpha Tokyo'));
    expect(batchTests, 1);
    expect(toggles, ['订阅 A:true']);
    expect(selected, ['JP - Alpha Tokyo']);
    expect(held, ['JP - Alpha Tokyo']);
    expect(tested, isEmpty);

    await tester.pumpWidget(
      host(
        HomeNodeList(
          nodes: [alpha, beta],
          latencyController: HomeLatencyController(),
          expandedSubscriptionGroups: const {'订阅 A'},
          selectedNode: null,
          testingNodeName: null,
          isConnecting: false,
          isBatchTesting: true,
          isConnected: true,
          textColor: Colors.white,
          subColor: Colors.white70,
          isDark: true,
          onTestAllLatency: () {},
          onTestLatency: (_) {},
          onSelectNode: (_) {},
          onLongPressNode: (_) {},
          onEditNode: (_) {},
          onToggleSubscriptionGroup: (_, __) {},
        ),
        themeMode: ThemeMode.dark,
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
