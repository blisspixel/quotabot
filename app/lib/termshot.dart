import 'package:flutter/widgets.dart';

/// Renders the ANSI output of `quotabot top` as a terminal-looking widget, so the
/// CLI view can be captured to a PNG for the README the same way the widget and
/// analytics screenshots are. Used only by screenshot mode; it parses the small,
/// fixed set of SGR codes the renderer emits (the named colors, 256-color orange,
/// 24-bit gradient, bold, dim, reset) into colored monospace runs.

const _defaultFg = Color(0xFFC9D1D9);
const _dim = Color(0xFF6E7681);
const _green = Color(0xFF3FB950);
const _amber = Color(0xFFD29922);
const _orange = Color(0xFFDB6D28);
const _red = Color(0xFFF85149);
const _cyan = Color(0xFF56B6C2);

class _Sgr {
  Color fill = _defaultFg;
  FontWeight weight = FontWeight.w400;
  void reset() {
    fill = _defaultFg;
    weight = FontWeight.w400;
  }

  void apply(List<String> params) {
    for (var i = 0; i < params.length; i++) {
      switch (params[i]) {
        case '0':
        case '':
          reset();
        case '1':
          weight = FontWeight.w700;
        case '2':
          fill = _dim;
        case '31':
          fill = _red;
        case '32':
          fill = _green;
        case '33':
          fill = _amber;
        case '36':
          fill = _cyan;
        case '38':
          // Extended color: 38;5;n (256) or 38;2;r;g;b (truecolor).
          if (i + 1 < params.length && params[i + 1] == '5') {
            final n = i + 2 < params.length
                ? int.tryParse(params[i + 2])
                : null;
            fill = n == 208 ? _orange : _defaultFg;
            i += 2;
          } else if (i + 4 < params.length && params[i + 1] == '2') {
            final r = int.tryParse(params[i + 2]) ?? 0;
            final g = int.tryParse(params[i + 3]) ?? 0;
            final b = int.tryParse(params[i + 4]) ?? 0;
            fill = Color.fromARGB(255, r, g, b);
            i += 4;
          }
      }
    }
  }
}

List<TextSpan> _parseLine(String line, _Sgr sgr) {
  final spans = <TextSpan>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isEmpty) return;
    spans.add(
      TextSpan(
        text: buf.toString(),
        style: TextStyle(color: sgr.fill, fontWeight: sgr.weight),
      ),
    );
    buf.clear();
  }

  var i = 0;
  while (i < line.length) {
    if (line.codeUnitAt(i) == 0x1B &&
        i + 1 < line.length &&
        line[i + 1] == '[') {
      final end = line.indexOf('m', i + 2);
      if (end < 0) break;
      flush();
      sgr.apply(line.substring(i + 2, end).split(';'));
      i = end + 1;
    } else {
      buf.write(line[i]);
      i++;
    }
  }
  flush();
  return spans;
}

/// A terminal window rendering [ansiLines] in a monospace font, sized to its
/// content so a RepaintBoundary capture is tight. Drawn as a real terminal
/// would look: a rounded window with a title bar, then a shell prompt invoking
/// the command, then the command's output.
class TerminalShot extends StatelessWidget {
  final List<String> ansiLines;
  const TerminalShot({super.key, required this.ansiLines});

  static const _titleBar = Color(0xFF161B22);
  static const _border = Color(0xFF30363D);

  Widget _dot(Color c) => Container(
    width: 11,
    height: 11,
    margin: const EdgeInsets.only(right: 7),
    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
  );

  @override
  Widget build(BuildContext context) {
    final sgr = _Sgr();
    const mono = TextStyle(fontFamily: 'Consolas', fontSize: 14, height: 1.45);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            color: _titleBar,
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dot(const Color(0xFF5A5F68)),
                _dot(const Color(0xFF5A5F68)),
                _dot(const Color(0xFF5A5F68)),
                const SizedBox(width: 14),
                const Text(
                  'quotabot top',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12.5,
                    color: _dim,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  softWrap: false,
                  text: const TextSpan(
                    style: mono,
                    children: [
                      TextSpan(
                        text: r'$ ',
                        style: TextStyle(color: _dim),
                      ),
                      TextSpan(
                        text: 'quotabot top',
                        style: TextStyle(color: _defaultFg),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                for (final line in ansiLines)
                  RichText(
                    softWrap: false,
                    text: TextSpan(
                      style: mono,
                      children: _parseLine(line, sgr),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
