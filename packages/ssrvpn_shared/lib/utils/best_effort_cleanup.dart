class CleanupFailure {
  const CleanupFailure({
    required this.step,
    required this.error,
    required this.stackTrace,
  });

  final int step;
  final Object error;
  final StackTrace stackTrace;
}

Future<List<CleanupFailure>> runBestEffortCleanup(
  List<Future<void> Function()> operations,
) async {
  final failures = <CleanupFailure>[];
  for (var index = 0; index < operations.length; index++) {
    try {
      await operations[index]();
    } catch (error, stackTrace) {
      failures.add(
        CleanupFailure(step: index, error: error, stackTrace: stackTrace),
      );
    }
  }
  return failures;
}
