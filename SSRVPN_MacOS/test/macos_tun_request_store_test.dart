import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/services/macos_tun_request_store.dart';

void main() {
  late Directory tempDir;
  late MacosTunRequestStore store;
  const nonce = '00112233445566778899aabbccddeeff';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ssrvpn-tun-request-');
    store = MacosTunRequestStore(dataDir: tempDir.path, appPid: 4242);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('publishes, transitions, and retires one owned generation', () async {
    await store.writeAtomically(store.value('active', nonce), nonce);
    expect(await store.currentGenerationExists(nonce), isTrue);

    expect(await store.transitionToRecovery(nonce), isTrue);
    expect(
      await File(store.requestPath).readAsString(),
      '${store.value('recovery', nonce)}\n',
    );

    await store.removeCurrentGeneration(nonce);
    expect(await File(store.requestPath).exists(), isFalse);
  });

  test('exclusive publication does not overwrite another owner', () async {
    await File(store.requestPath).writeAsString('other-owner\n');

    await expectLater(
      store.writeAtomically(store.value('active', nonce), nonce),
      throwsStateError,
    );

    expect(await File(store.requestPath).readAsString(), 'other-owner\n');
  });

  test('recovery reader rejects links, multiline, and oversized values',
      () async {
    final valid = File('${tempDir.path}/valid')
      ..writeAsStringSync('${store.value('recovery', nonce)}\n');
    expect(
      await MacosTunRequestStore.readRecoveryRequest(valid.path),
      store.value('recovery', nonce),
    );

    final multiline = File('${tempDir.path}/multiline')
      ..writeAsStringSync('4242\n4243\n');
    expect(
      await MacosTunRequestStore.readRecoveryRequest(multiline.path),
      isNull,
    );

    final oversized = File('${tempDir.path}/oversized')
      ..writeAsStringSync('${'x' * 65}\n');
    expect(
      await MacosTunRequestStore.readRecoveryRequest(oversized.path),
      isNull,
    );

    final link = Link('${tempDir.path}/link')..createSync(valid.path);
    expect(
      await MacosTunRequestStore.readRecoveryRequest(link.path),
      isNull,
    );
  });
}
