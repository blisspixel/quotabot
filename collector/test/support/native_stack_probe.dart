import 'dart:io';
import 'dart:isolate';

void main() {
  RawReceivePort((_) {}, 'quotabot diagnostic held port');
  stderr.writeln('fixture VM pid: $pid');
  stderr.writeln('fixture native probe ready');
}
