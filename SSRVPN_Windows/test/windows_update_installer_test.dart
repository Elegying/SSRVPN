import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_update_installer.dart';

void main() {
  late Directory root;
  late File installer;
  final bytes = utf8.encode('synthetic installer');
  setUp(() {
    root = Directory.systemTemp.createTempSync('update installer ');
    installer = File('${root.path}/SSRVPN_Setup_v9.9.9.exe')
      ..writeAsBytesSync(bytes);
  });
  tearDown(() => root.deleteSync(recursive: true));
  test('verified package is sent as one argument to the trusted shell broker',
      () async {
    String? launched;
    List<String>? arguments;
    await WindowsUpdateInstaller.open(
        installer, sha256.convert(bytes).toString(),
        explorerPath: () => r'C:\Windows\explorer.exe',
        start: (path, args) async {
          launched = path;
          arguments = args;
        });
    expect(launched, r'C:\Windows\explorer.exe');
    expect(arguments, [installer.absolute.path]);
    expect(installer.readAsBytesSync(), bytes);
  });
  test('missing or changed digest cannot launch, and keeps the package',
      () async {
    var launches = 0;
    for (final digest in [null, '', '0' * 64]) {
      await expectLater(
          WindowsUpdateInstaller.open(installer, digest,
              explorerPath: () => 'unused',
              start: (executable, arguments) async {
                launches++;
              }),
          throwsStateError);
    }
    expect(launches, 0);
    expect(installer.existsSync(), isTrue);
  });
  test('broker failure preserves installer for manual recovery', () async {
    await expectLater(
        WindowsUpdateInstaller.open(installer, sha256.convert(bytes).toString(),
            explorerPath: () => 'explorer.exe',
            start: (executable, arguments) async =>
                throw const ProcessException('synthetic', [])),
        throwsA(isA<ProcessException>()));
    expect(installer.readAsBytesSync(), bytes);
  });
}
