import 'package:quotabot_collector/cli_layout.dart';
import 'package:test/test.dart';

void main() {
  test('existing newlines stay line breaks while each line wraps', () {
    final wrapped = wrapCliLine('alpha beta\ngamma delta epsilon', 12);

    expect(wrapped, ['alpha beta', 'gamma delta', 'epsilon']);
  });

  test('a word longer than the width is not split', () {
    expect(wrapCliLine('abcdefghijklmno', 8), ['abcdefghijklmno']);
  });
}
