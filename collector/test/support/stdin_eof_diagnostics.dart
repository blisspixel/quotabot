import 'dart:async';
import 'dart:io';

/// Changes only the parent's owned pipe after the original exit assertion has
/// already failed and its passive snapshots have completed. Recovery is evidence
/// of dependence on that pipe, never a passing lifecycle check or a root cause.
Future<String> observeStdinEofAfterFailure(Process target) async {
  final elapsed = Stopwatch()..start();
  Duration remaining() {
    final microseconds = 1000000 - elapsed.elapsedMicroseconds;
    if (microseconds <= 0) throw TimeoutException('EOF observation expired');
    return Duration(microseconds: microseconds);
  }

  try {
    await target.stdin.close().timeout(remaining());
  } catch (_) {
    return 'stdin EOF writer closure unavailable';
  }
  try {
    final code = await target.exitCode.timeout(remaining());
    return 'stdin EOF writer closed; process exited with code $code';
  } on TimeoutException {
    return 'stdin EOF writer closed; process exit not observed';
  } catch (_) {
    return 'stdin EOF writer closed; process observation unavailable';
  }
}
