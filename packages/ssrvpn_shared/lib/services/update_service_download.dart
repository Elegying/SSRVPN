part of 'update_service.dart';

Future<File> _downloadVerifiedUpdate(
  AppUpdateInfo update, {
  required Directory outputDirectory,
  required String fileName,
  int maxBytes = SharedUpdateService.maxDesktopUpdateBytes,
  http.Client? client,
  Duration timeout = const Duration(minutes: 2),
  void Function(int receivedBytes, int? totalBytes)? onProgress,
  VerifiedUpdateCancellation? cancellation,
  VerifiedUpdateFilePublisher? filePublisher,
}) async {
  cancellation?.throwIfCancelled();
  if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(fileName)) {
    throw const FormatException('Invalid update file name');
  }
  final expectedSha256 = update.sha256?.trim().toLowerCase();
  if (expectedSha256 == null ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256)) {
    throw StateError('缺少有效的更新文件 SHA256，已取消更新');
  }
  final uris = <Uri>[
    SharedUpdateService.validateDownloadUrl(update.downloadUrl)
  ];
  final fallback = update.fallbackDownloadUrl?.trim();
  if (fallback != null && fallback.isNotEmpty) {
    final fallbackUri = SharedUpdateService.validateDownloadUrl(fallback);
    if (fallbackUri != uris.first) uris.add(fallbackUri);
  }

  await _awaitWithCancellation(
    outputDirectory.create(recursive: true),
    cancellation,
  );
  final destination = File('${outputDirectory.path}/$fileName');
  final recovered = await _withPublicationLock(
    destination,
    cancellation: cancellation,
    action: () => _recoverInterruptedPublicationLocked(
      destination,
      expectedSha256: expectedSha256,
      maxBytes: maxBytes,
      cancellation: cancellation,
      filePublisher: filePublisher,
    ),
  );
  if (recovered) {
    return destination;
  }
  final publicationId = '${pid}_${DateTime.now().microsecondsSinceEpoch}_'
      '${math.Random.secure().nextInt(0x7fffffff)}';
  final temporary = File('${destination.path}.part.$publicationId');
  cancellation?.throwIfCancelled();
  final ownsClient = client == null;
  final httpClient = client ?? http.Client();
  try {
    if (ownsClient) cancellation?._attach(httpClient.close);
    var verifiedDownloadReady = false;
    for (var attempt = 0; attempt < uris.length; attempt++) {
      cancellation?.throwIfCancelled();
      final attemptClock = Stopwatch()..start();
      try {
        final request = http.Request('GET', uris[attempt])
          ..headers['User-Agent'] = 'SSRVPN/${update.version}';
        final response = await _sendResponse(
          httpClient,
          request,
          cancellation,
          attemptClock: attemptClock,
          timeout: timeout,
        );
        if (response case http.BaseResponseWithUrl(:final url)) {
          if (url.scheme != 'https' || url.host.isEmpty) {
            await response.stream.listen((_) {}).cancel();
            throw const FormatException('Invalid final update URL');
          }
        }
        if (response.statusCode != HttpStatus.ok) {
          await response.stream.listen((_) {}).cancel();
          throw StateError('下载更新失败: HTTP ${response.statusCode}');
        }
        final total = response.contentLength;
        if (total != null && total > maxBytes) {
          await response.stream.listen((_) {}).cancel();
          throw StateError('更新文件过大，已取消更新');
        }

        var received = 0;
        final output = await temporary.open(mode: FileMode.write);
        final digestSink = _UpdateDigestSink();
        final hashSink = sha256.startChunkedConversion(digestSink);
        var hashClosed = false;
        late final String actualSha256;
        try {
          await for (final chunk in _cancellableStream(
            response.stream,
            cancellation,
            attemptClock: attemptClock,
            timeout: timeout,
          )) {
            cancellation?.throwIfCancelled();
            received += chunk.length;
            if (received > maxBytes) {
              throw StateError('更新文件过大，已取消更新');
            }
            hashSink.add(chunk);
            await output.writeFrom(chunk);
            onProgress?.call(received, total);
          }
          cancellation?.throwIfCancelled();
          hashClosed = true;
          hashSink.close();
          actualSha256 = digestSink.value.toString();
        } finally {
          if (!hashClosed) hashSink.close();
          await output.close();
        }
        cancellation?.throwIfCancelled();
        if (actualSha256 != expectedSha256) {
          throw StateError('更新文件 SHA256 校验失败，已取消更新');
        }
        cancellation?.throwIfCancelled();
        verifiedDownloadReady = true;
        break;
      } catch (_) {
        if (await temporary.exists()) await temporary.delete();
        cancellation?.throwIfCancelled();
        if (attempt == uris.length - 1) rethrow;
      }
    }
    if (!verifiedDownloadReady) {
      throw StateError('没有可用的更新下载地址');
    }

    try {
      await _notifyPublicationStep(
        VerifiedUpdatePublicationTestStep.downloadVerified,
      );
      cancellation?.throwIfCancelled();
      final verifiedLength = await _awaitWithCancellation(
        temporary.length(),
        cancellation,
      );
      await _withPublicationLock<void>(
        destination,
        cancellation: cancellation,
        action: () => _publishVerifiedFileLocked(
          temporary: temporary,
          destination: destination,
          expectedSha256: expectedSha256,
          expectedLength: verifiedLength,
          maxBytes: maxBytes,
          cancellation: cancellation,
          filePublisher: filePublisher,
        ),
      );
    } catch (_) {
      await _deleteRecoveryBackupBestEffort(temporary, null);
      rethrow;
    }
    return destination;
  } finally {
    cancellation?._detach();
    if (ownsClient) httpClient.close();
  }
}

Future<T> _awaitWithCancellation<T>(
  Future<T> operation,
  VerifiedUpdateCancellation? cancellation,
) {
  if (cancellation == null) return operation;
  return Future.any<T>([
    operation,
    cancellation.whenCancelled.then<T>(
      (_) => throw VerifiedUpdateCancelled(),
    ),
  ]);
}

Future<http.StreamedResponse> _sendResponse(
  http.Client client,
  http.BaseRequest request,
  VerifiedUpdateCancellation? cancellation, {
  required Stopwatch attemptClock,
  required Duration timeout,
}) async {
  final responseFuture = client.send(request);
  try {
    return await _awaitWithCancellation(
      responseFuture.timeout(_remainingAttemptTime(attemptClock, timeout)),
      cancellation,
    );
  } catch (_) {
    unawaited(
      responseFuture.then<void>(
        _cancelUnusedResponse,
        onError: (Object _, StackTrace __) {},
      ),
    );
    rethrow;
  }
}

Future<void> _cancelUnusedResponse(
  http.StreamedResponse response,
) async {
  try {
    final subscription = response.stream.listen((_) {});
    await subscription.cancel();
  } catch (_) {
    // The request already lost its timeout/cancellation race. Cleanup is
    // best-effort and must not replace the original error.
  }
}

Stream<List<int>> _cancellableStream(
  Stream<List<int>> source,
  VerifiedUpdateCancellation? cancellation, {
  required Stopwatch attemptClock,
  required Duration timeout,
}) async* {
  final iterator = StreamIterator<List<int>>(source);
  try {
    while (await _awaitWithCancellation(
      iterator.moveNext().timeout(_remainingAttemptTime(attemptClock, timeout)),
      cancellation,
    )) {
      yield iterator.current;
    }
  } finally {
    await iterator.cancel();
  }
}

Duration _remainingAttemptTime(
  Stopwatch attemptClock,
  Duration timeout,
) {
  final remaining = timeout - attemptClock.elapsed;
  if (remaining <= Duration.zero) {
    throw TimeoutException('更新下载超时');
  }
  return remaining;
}

class _UpdateDigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
