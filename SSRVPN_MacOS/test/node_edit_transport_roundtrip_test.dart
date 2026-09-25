import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssrvpn_macos/screens/node_edit_screen.dart';
import 'package:ssrvpn_macos/services/settings_service.dart';
import 'package:ssrvpn_macos/services/subscription_service.dart';
import 'package:ssrvpn_macos/theme/app_theme.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';

class _EditorSubscription extends SubscriptionServiceBase
    implements SubscriptionService {
  @override
  Future<String?> fetchSubscription(String url,
          {int maxRetries = 3, SubscriptionRefreshControl? control}) async =>
      throw StateError('unexpected network fetch');
}

void main() {
  for (final type in ['hysteria2', 'hysteria']) {
    testWidgets('renaming $type preserves transport options on disk',
        (tester) async {
      late Directory directory;
      late _EditorSubscription subscription;
      late SettingsService settings;
      final original = <String, dynamic>{
        'name': 'Original',
        'type': type,
        'server': 'fixture.invalid',
        'port': 443,
        if (type == 'hysteria2') ...{
          'password': ' synthetic-password ',
          'obfs': 'salamander',
          'obfs-password': ' synthetic-obfs ',
        } else ...{
          'auth-str': ' synthetic-auth ',
          'protocol': 'wechat-video',
          'obfs': 'synthetic-obfs',
          'up': '10 Mbps',
          'down': '50 Mbps',
        },
      };
      await tester.runAsync(() async {
        directory =
            await Directory.systemTemp.createTemp('ssrvpn-node-roundtrip-');
        subscription = _EditorSubscription();
        await subscription.init(directory.path);
        await subscription.setRawYaml(jsonEncode({
          'proxies': [original]
        }));
        settings = await SettingsService.createForTesting(
          settings: AppSettings(),
          dataDir: directory.path,
          settingsPath: '${directory.path}/settings.json',
          readApiSecret: () async => 'synthetic-api-secret',
          writeApiSecret: (_) async {},
        );
      });
      addTearDown(() async {
        subscription.dispose();
        settings.dispose();
        await directory.delete(recursive: true);
      });
      expect(subscription.allNodes, hasLength(1));
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<SubscriptionService>.value(
              value: subscription),
          ChangeNotifierProvider<SettingsService>.value(value: settings),
        ],
        child: SsrvpnAppearanceScope(
          settings: AppSettings(
            glassEffectLevel: GlassEffectLevel.none,
            backgroundStyle: BackgroundStyle.black,
            dynamicBackground: false,
          ),
          child: MaterialApp(
            theme: AppTheme.light,
            home: NodeEditScreen(node: subscription.allNodes.single),
          ),
        ),
      ));
      await tester.enterText(find.byType(TextFormField).first, 'Renamed');
      final save = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
          .onPressed! as Future<void> Function();
      await tester.runAsync(save);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(subscription.allNodes.single.name, 'Renamed');
      late Map<String, dynamic> saved;
      await tester.runAsync(() async {
        final reloaded = _EditorSubscription();
        await reloaded.init(directory.path);
        saved = reloaded.allNodes.single.extra;
        reloaded.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      for (final entry in original.entries) {
        expect(saved[entry.key], entry.key == 'name' ? 'Renamed' : entry.value,
            reason: 'Renaming must preserve ${entry.key} on disk');
      }
    });
  }
}
