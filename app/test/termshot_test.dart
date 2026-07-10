import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/termshot.dart';

List<TextSpan> _outputSpans(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .expand((rich) => (rich.text as TextSpan).children ?? const <InlineSpan>[])
    .whereType<TextSpan>()
    .toList();

TextSpan _span(List<TextSpan> spans, String text) =>
    spans.singleWhere((span) => span.text == text);

void main() {
  testWidgets('terminal shot renders the supported ANSI color contract', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: TerminalShot(
          ansiLines: [
            'plain',
            '\x1b[1;32mbold green\x1b[0m normal',
            '\x1b[2mdim\x1b[31mred\x1b[33mamber\x1b[36mcyan\x1b[0m',
            '\x1b[38;5;208morange\x1b[38;5;42mdefault\x1b[0m',
            '\x1b[38;2;1;2;3mtruecolor\x1b[38;2;x;y;zminvalid\x1b[0m',
            'broken \x1b[31',
          ],
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('quotabot top'), findsWidgets);
    final spans = _outputSpans(tester);
    expect(_span(spans, 'plain').style?.color, const Color(0xFFC9D1D9));
    expect(_span(spans, 'bold green').style?.color, const Color(0xFF3FB950));
    expect(_span(spans, 'bold green').style?.fontWeight, FontWeight.w700);
    expect(_span(spans, ' normal').style?.fontWeight, FontWeight.w400);
    expect(_span(spans, 'dim').style?.color, const Color(0xFF6E7681));
    expect(_span(spans, 'red').style?.color, const Color(0xFFF85149));
    expect(_span(spans, 'amber').style?.color, const Color(0xFFD29922));
    expect(_span(spans, 'cyan').style?.color, const Color(0xFF56B6C2));
    expect(_span(spans, 'orange').style?.color, const Color(0xFFDB6D28));
    expect(_span(spans, 'default').style?.color, const Color(0xFFC9D1D9));
    expect(_span(spans, 'truecolor').style?.color, const Color(0xFF010203));
    expect(_span(spans, 'invalid').style?.color, const Color(0xFF000000));
    expect(_span(spans, 'broken ').style?.color, const Color(0xFFC9D1D9));
  });

  testWidgets('terminal shot handles empty output without layout failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: TerminalShot(ansiLines: []),
      ),
    );

    expect(find.text('quotabot top'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
