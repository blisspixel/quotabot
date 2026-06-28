import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/logos.dart';

void main() {
  test('every supported provider has a dedicated (non-fallback) logo', () {
    for (final p in providersWithLogo) {
      final painter = providerLogoPainter(p, const Color(0xFF000000));
      expect(
        painter.runtimeType.toString(),
        isNot(contains('Fallback')),
        reason: 'provider "$p" should have a branded mark, not the dot',
      );
    }
  });

  test('lemonade specifically resolves to a real mark', () {
    expect(providersWithLogo, contains('lemonade'));
    expect(
      providerLogoPainter(
        'lemonade',
        const Color(0xFF000000),
      ).runtimeType.toString(),
      isNot(contains('Fallback')),
    );
  });

  test('an unknown provider falls back gracefully', () {
    expect(
      providerLogoPainter('does-not-exist', const Color(0xFF000000)),
      isA<CustomPainter>(),
    );
  });
}
