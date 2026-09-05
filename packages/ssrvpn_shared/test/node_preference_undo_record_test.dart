import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  late Directory directory;
  late File journal;
  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('ssrvpn-preference-undo-');
    journal = File('${directory.path}/${SubscriptionUndoRecord.fileName}');
  });
  tearDown(() => directory.delete(recursive: true));

  for (final preference in [
    null,
    {'originalName': 'Original', 'updatedName': 'New', 'id': ''},
    {'originalName': 'Original', 'updatedName': 'New\t', 'id': 'id'},
    {'originalName': 42, 'updatedName': 'New', 'id': 'id'},
  ]) {
    test('invalid v2 preference is rejected before recovery: $preference',
        () async {
      await journal.writeAsString(jsonEncode({
        'version': 2,
        'files': {'subscriptions.json': '[]', 'subscription_cache.yaml': null},
        'preference': preference,
      }));
      await expectLater(
          SubscriptionUndoRecord.read(journal), throwsFormatException);
    });
  }

  test('undo record path cannot be a directory or a symbolic link', () async {
    await Directory(journal.path).create();
    await expectLater(SubscriptionUndoRecord.read(journal),
        throwsA(isA<FileSystemException>()));
    await Directory(journal.path).delete();
    final target = File('${directory.path}/target.json');
    await target.writeAsString('{}');
    await Link(journal.path).create(target.path);
    await expectLater(SubscriptionUndoRecord.read(journal),
        throwsA(isA<FileSystemException>()));
    expect(await target.readAsString(), '{}');
  },
      skip: Platform.isWindows
          ? 'Windows symlink creation requires host privileges'
          : false);

  test(
      'recovery ownership protects a repeated independent choice of the new name',
      () {
    const rename = NodePreferenceRename('Original', 'New', 'id');
    final settings = AppSettings(
        lastSelectedNodeName: 'New', lastSelectedNodeRenameId: 'id');
    final independent = settings.copyWith(lastSelectedNodeName: 'New').toJson();
    expect(rename.recoverJson(independent), isFalse);
    expect(independent['lastSelectedNodeName'], 'New');
    final owned = settings.copyWith(proxyPort: 8890).toJson();
    expect(rename.recoverJson(owned), isTrue);
    expect(owned['lastSelectedNodeName'], 'Original');
    expect(owned['proxyPort'], 8890);
    expect(rename.recoverJson(owned), isFalse);
  });
}
