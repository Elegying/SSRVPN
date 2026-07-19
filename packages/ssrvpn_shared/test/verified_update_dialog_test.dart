import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ssrvpn_shared/services/update_checker.dart';
import 'package:ssrvpn_shared/services/update_service.dart';

void main() {
  testWidgets('cancelling a desktop update closes the progress dialog',
      (tester) async {
    final outputDirectory =
        Directory.systemTemp.createTempSync('ssrvpn-update-dialog-');
    addTearDown(() {
      if (outputDirectory.existsSync()) {
        outputDirectory.deleteSync(recursive: true);
      }
    });
    final response = Completer<http.StreamedResponse>();
    final client = _StreamClient((_) => response.future);
    var opened = false;
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    unawaited(
      SharedUpdateService.downloadAndOpenVerifiedUpdate(
        context,
        const AppUpdateInfo(
          version: '9.9.9',
          downloadUrl: 'https://example.com/SSRVPN.dmg',
          changelog: '',
          sha256:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
        fileName: 'SSRVPN.dmg',
        outputDirectory: outputDirectory,
        client: client,
        openFile: (_) async {
          opened = true;
        },
      ),
    );

    await tester.pump();
    expect(find.text('取消更新'), findsOneWidget);
    await tester.tap(find.text('取消更新'));
    await tester.pumpAndSettle();

    expect(find.text('正在下载更新'), findsNothing);
    expect(find.text('更新失败'), findsNothing);
    expect(opened, isFalse);
    expect(SharedUpdateService.isVerifiedDownloadInProgress, isFalse);
  });
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
