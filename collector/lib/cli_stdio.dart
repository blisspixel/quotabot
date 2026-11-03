/// Classifies a failed write to the CLI's standard streams.
///
/// A closed pipe means the reader left early, as in `quotabot --help | head`.
/// That is a quiet success. Any other stdio write failure is one stderr line
/// and a nonzero exit. File and network errors are not stdio writes.
library;

import 'dart:async';
import 'dart:io';

/// Decision for one stdio write failure.
class StdioWriteFault {
  /// 0 when the reader closed the stream. 1 for any other stdio write failure.
  final int exitCode;

  /// Null when the reader closed the stream. Otherwise one stderr line.
  final String? message;

  const StdioWriteFault._(this.exitCode, this.message);

  /// The reader closed stdout or stderr before the write finished.
  bool get closed => message == null;

  static const closedReader = StdioWriteFault._(0, null);
}

/// POSIX EPIPE, and the Windows pipe closures Dart reports for the same case.
const _closedPipeCodes = <int>{
  32, // EPIPE
  109, // ERROR_BROKEN_PIPE
  232, // ERROR_NO_DATA ("The pipe is being closed")
  233, // ERROR_PIPE_NOT_CONNECTED
};

/// Returns a fault when [error] came from writing stdout or stderr.
/// Returns null for every other error so the caller can rethrow it.
StdioWriteFault? classifyStdioWrite(Object error) {
  if (!_isStdioWrite(error)) return null;
  if (_isClosedPipe(error)) return StdioWriteFault.closedReader;
  return StdioWriteFault._(
    1,
    'quotabot: write failed: ${_oneLine(_faultDetail(error))}',
  );
}

bool _isStdioWrite(Object error) {
  if (error is StdoutException) return true;
  if (error is FileSystemException) {
    final path = error.path;
    final emptyPath = path == null || path.isEmpty;
    return emptyPath && error.message.toLowerCase().contains('write');
  }
  return false;
}

bool _isClosedPipe(Object error) {
  final os = _osError(error);
  final code = os?.errorCode;
  if (code != null && _closedPipeCodes.contains(code)) return true;
  final text = '${os?.message ?? ''} $error'.toLowerCase();
  return text.contains('broken pipe') ||
      text.contains('pipe is being closed') ||
      text.contains('pipe has been ended');
}

OSError? _osError(Object error) => switch (error) {
      StdoutException(:final osError) => osError,
      FileSystemException(:final osError) => osError,
      _ => null,
    };

String _faultDetail(Object error) {
  final os = _osError(error);
  final message = os?.message ?? '';
  if (message.trim().isNotEmpty) return message;
  if (error is StdoutException && error.message.trim().isNotEmpty) {
    return error.message;
  }
  if (error is FileSystemException && error.message.trim().isNotEmpty) {
    return error.message;
  }
  return 'output write failed';
}

String _oneLine(String value) {
  final collapsed = value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  if (collapsed.isEmpty) return 'output write failed';
  const max = 200;
  return collapsed.length <= max ? collapsed : collapsed.substring(0, max);
}

/// The exit code to keep after [fault].
///
/// A closed pipe means the reader left. It must not replace an exit code the
/// command already chose, and a successful command stays 0. Any other stdio
/// write failure becomes 1 only when the command had not already failed.
int applyStdioWriteFault(int currentExitCode, StdioWriteFault fault) {
  if (fault.closed || currentExitCode != 0) return currentExitCode;
  return fault.exitCode;
}

/// Records one stdio write failure. Returns false when [error] is unrelated.
bool finishCliStdioWrite(Object error) {
  final fault = classifyStdioWrite(error);
  if (fault == null) return false;
  if (fault.message != null) {
    try {
      stderr.writeln(fault.message);
    } on Object {
      // The failure report itself could not be written.
    }
  }
  exitCode = applyStdioWriteFault(exitCode, fault);
  return true;
}

/// Runs [body] so a closed pipe stays quiet and any other error still reaches
/// the root zone. [onFinally] runs even when [body] fails.
Future<void> runCliBody(
  Future<void> Function() body, {
  FutureOr<void> Function()? onFinally,
}) async {
  await runZonedGuarded(() async {
    try {
      await body();
    } on Object catch (error) {
      if (!finishCliStdioWrite(error)) rethrow;
    } finally {
      final done = onFinally;
      if (done != null) await done();
    }
  }, (error, stack) {
    if (finishCliStdioWrite(error)) return;
    // This handler runs in the parent zone. From main that parent is the root
    // zone, so Zone.current.parent is null and would drop the error.
    Zone.root.handleUncaughtError(error, stack);
  });
}
