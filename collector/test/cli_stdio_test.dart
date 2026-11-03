import 'dart:io';

import 'package:quotabot_collector/cli_stdio.dart';
import 'package:test/test.dart';

void main() {
  StdioWriteFault fault(Object error) {
    final classified = classifyStdioWrite(error);
    expect(classified, isNotNull, reason: '$error');
    return classified!;
  }

  test('a closed pipe is a quiet success', () {
    const cases = [
      (32, 'Broken pipe'),
      (109, 'The pipe has been ended'),
      (232, 'The pipe is being closed'),
      (233, 'The pipe is not connected'),
    ];
    for (final entry in cases) {
      final error = FileSystemException(
        'writeFrom failed',
        '',
        OSError(entry.$2, entry.$1),
      );
      final classified = fault(error);
      expect(classified.closed, isTrue, reason: 'errno ${entry.$1}');
      expect(classified.exitCode, 0);
      expect(classified.message, isNull);
    }
  });

  test('a StdoutException for a closed pipe is the same quiet success', () {
    final classified = fault(
      const StdoutException('writeFrom failed', OSError('Broken pipe', 32)),
    );
    expect(classified.closed, isTrue);
    expect(classified.message, isNull);
  });

  test('a real stdio write failure stays one line and nonzero', () {
    final classified = fault(
      const FileSystemException(
        'writeFrom failed',
        '',
        OSError('No space left on device', 28),
      ),
    );
    expect(classified.closed, isFalse);
    expect(classified.exitCode, 1);
    expect(
        classified.message, 'quotabot: write failed: No space left on device');
    expect(classified.message, isNot(contains('\n')));
  });

  test('a Windows disk-full write is not a closed pipe', () {
    final classified = fault(
      const FileSystemException(
        'writeFrom failed',
        '',
        OSError('There is not enough space on the disk.', 112),
      ),
    );
    expect(classified.exitCode, 1);
    expect(
      classified.message,
      contains('not enough space on the disk'),
    );
  });

  test('file and program errors are not stdio write failures', () {
    expect(
      classifyStdioWrite(
        const FileSystemException(
          'read failed',
          r'C:\quota\cache.json',
          OSError('Access is denied', 5),
        ),
      ),
      isNull,
    );
    expect(
      classifyStdioWrite(
        const FileSystemException(
          'write failed',
          r'C:\quota\out.txt',
          OSError('Access is denied', 5),
        ),
      ),
      isNull,
    );
    expect(classifyStdioWrite(StateError('boom')), isNull);
    expect(classifyStdioWrite(const SocketException('failed host lookup')),
        isNull);
  });
}
