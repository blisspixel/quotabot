import 'package:quotabot_collector/sqlite_loader.dart';
import 'package:test/test.dart';

void main() {
  test('Windows sqlite candidate does not trust WINDIR-derived paths', () {
    expect(
      trustedSqliteCandidates(isWindows: true, isMacOS: false),
      [r'C:\Windows\System32\winsqlite3.dll'],
    );
  });

  test('non-Windows sqlite candidates remain absolute system paths', () {
    for (final path in trustedSqliteCandidates(
      isWindows: false,
      isMacOS: false,
    )) {
      expect(path.startsWith('/'), isTrue, reason: path);
      expect(path, contains('sqlite3'));
    }
  });
}
