import 'package:quotabot_collector/palette.dart';
import 'package:test/test.dart';

void main() {
  test('built-in palettes resolve by name', () {
    expect(paletteFromSpec('green').name, 'green');
    expect(paletteFromSpec('SYNTHWAVE').name, 'synthwave'); // case-insensitive
    expect(paletteNames, containsAll(['default', 'green', 'dark', 'light']));
  });

  test('absent or unknown specs fall back to default', () {
    expect(paletteFromSpec(null).name, 'default');
    expect(paletteFromSpec('').name, 'default');
    expect(paletteFromSpec('nonsense').name, 'default');
  });

  test('a custom spec parses four hex colors', () {
    final p = paletteFromSpec('custom:39ff14-00cc5a-009946-005a32');
    expect(p.name, 'custom');
    expect([p.healthy.r, p.healthy.g, p.healthy.b], [0x39, 0xFF, 0x14]);
    expect([p.spent.r, p.spent.g, p.spent.b], [0x00, 0x5A, 0x32]);
    // Accent defaults when not supplied.
    expect(p.accent.r, kDefaultPalette.accent.r);
  });

  test('a malformed custom spec falls back to default, never crashes', () {
    expect(paletteFromSpec('custom:nope').name, 'default');
    expect(paletteFromSpec('custom:39ff14-00cc5a').name, 'default'); // too few
    expect(
        paletteFromSpec('custom:zzzzzz-00cc5a-009946-005a32').name, 'default');
  });

  test('rgbFor spans spent at 0 to healthy at 100', () {
    final p = paletteFromSpec('default');
    final spent = p.rgbFor(0);
    final healthy = p.rgbFor(100);
    expect([spent.r, spent.g, spent.b], [p.spent.r, p.spent.g, p.spent.b]);
    expect([healthy.r, healthy.g, healthy.b],
        [p.healthy.r, p.healthy.g, p.healthy.b]);
  });
}
