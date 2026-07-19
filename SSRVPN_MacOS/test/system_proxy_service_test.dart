import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/services/system_proxy_service.dart';

void main() {
  test('legacy proxy snapshot without ownership is discarded safely', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'ssrvpn_macos_proxy_legacy_',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final snapshot = File('${tempDirectory.path}/system_proxy.json');
    await snapshot.writeAsString(
      jsonEncode({
        'Wi-Fi': {
          'web': {'enabled': true, 'server': '127.0.0.1', 'port': 7890},
        },
      }),
      flush: true,
    );

    final service = SystemProxyService();
    await service.initialize(tempDirectory.path);

    expect(await snapshot.exists(), isFalse);
    expect(service.recoveryPending, isFalse);
    expect(service.lastError, isNull);
  });
}
