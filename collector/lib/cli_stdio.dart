/// Classifies a failed write to the CLI's standard streams.
///
/// A closed pipe means the reader left early, as in `quotabot --help | head`.
/// That is a quiet success. Any other stdio write failure is one stderr line
/// and a nonzero exit. File and network errors are not stdio writes.
library;

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
