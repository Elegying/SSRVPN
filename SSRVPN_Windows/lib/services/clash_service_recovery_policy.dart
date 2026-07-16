part of 'clash_service.dart';

const _unexpectedExitProxyRecoveryDelays = <Duration>[
  Duration(milliseconds: 250),
  Duration(milliseconds: 750),
  Duration(milliseconds: 1500),
];

enum ProxyRecoveryDisposition {
  journalTerminal,
  endpointSafeWithPendingJournal,
  endpointMayStillBeOwned,
}

ProxyRecoveryDisposition classifyProxyRecoveryDisposition({
  required bool journalTerminal,
  required bool endpointSafeWithPendingRecovery,
}) {
  if (journalTerminal) return ProxyRecoveryDisposition.journalTerminal;
  if (endpointSafeWithPendingRecovery) {
    return ProxyRecoveryDisposition.endpointSafeWithPendingJournal;
  }
  return ProxyRecoveryDisposition.endpointMayStillBeOwned;
}

bool isUnexpectedCoreExit({
  required bool ownsProcess,
  required bool stoppingCore,
  required bool stopInProgress,
}) =>
    ownsProcess && !stoppingCore && !stopInProgress;

bool hasActiveUnexpectedExitRecoveryIntent(
  int? generation,
  bool Function(int generation) isCurrent,
) =>
    generation != null && isCurrent(generation);

/// Retries a failed proxy restore without overlapping registry transactions.
///
/// There is one initial attempt plus one attempt after every delay. The caller
/// is responsible for restoring the local proxy listener if all attempts fail.
Future<bool> retryUnexpectedExitSystemProxyRecovery({
  required Future<bool> Function() clearProxy,
  List<Duration> retryDelays = _unexpectedExitProxyRecoveryDelays,
  Future<void> Function(Duration duration)? wait,
  void Function(int attempt, int totalAttempts)? onAttemptFailed,
}) async {
  final waitFor = wait ?? (duration) => Future<void>.delayed(duration);
  final totalAttempts = retryDelays.length + 1;
  for (var attempt = 1; attempt <= totalAttempts; attempt++) {
    try {
      if (await clearProxy()) return true;
    } catch (_) {}
    onAttemptFailed?.call(attempt, totalAttempts);
    if (attempt < totalAttempts) {
      await waitFor(retryDelays[attempt - 1]);
    }
  }
  return false;
}
