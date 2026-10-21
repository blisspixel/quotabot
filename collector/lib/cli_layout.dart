/// Width-aware wrapping for human CLI lines.
library;

final RegExp _ansiSequence = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

/// Visible columns in [line], ignoring ANSI color sequences.
int visibleWidth(String line) => line.replaceAll(_ansiSequence, '').length;

/// Wraps [line] to [width] visible columns, breaking on spaces.
///
/// Existing newlines stay as line breaks. Continuation lines start with [hang]
/// spaces. A single word longer than the width is kept whole so an escape
/// sequence or identifier is never split. Do not pass JSON through this
/// helper: a wrapped string is no longer valid JSON.
List<String> wrapCliLine(String line, int width, {int hang = 0}) {
  if (line.contains('\n')) {
    final columns = width < 8 ? 8 : width;
    return [
      for (final part in line.split('\n')) ..._wrapCliLine(part, columns, hang),
    ];
  }
  return _wrapCliLine(line, width < 8 ? 8 : width, hang);
}

List<String> _wrapCliLine(String line, int columns, int hang) {
  if (visibleWidth(line) <= columns) return [line];
  final indentCount = hang <= 0 || hang >= columns - 4 ? 0 : hang;
  final words = line.split(' ').where((word) => word.isNotEmpty).toList();
  final lines = <String>[];
  final current = StringBuffer();
  var currentWidth = 0;

  void push() {
    lines.add(current.toString().trimRight());
    current.clear();
    currentWidth = 0;
    if (indentCount > 0) {
      current.write(' ' * indentCount);
      currentWidth = indentCount;
    }
  }

  for (final word in words) {
    final wordWidth = visibleWidth(word);
    final gap = currentWidth == 0 ? 0 : 1;
    if (currentWidth > indentCount &&
        currentWidth + gap + wordWidth > columns) {
      push();
    }
    if (current.isNotEmpty && !current.toString().endsWith(' ')) {
      current.write(' ');
      currentWidth += 1;
    }
    current.write(word);
    currentWidth += wordWidth;
  }
  if (current.isNotEmpty) lines.add(current.toString().trimRight());
  return lines;
}
