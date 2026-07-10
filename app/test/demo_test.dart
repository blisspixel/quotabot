import 'package:flutter_test/flutter_test.dart';
import 'package:quotabot/demo.dart';

void main() {
  test('demo fleet is complete, synthetic, and internally consistent', () {
    final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final data = demoData();
    final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    expect(data.map((quota) => quota.provider).toSet(), {
      'claude',
      'codex',
      'antigravity',
      'grok',
      'cursor',
      'ollama',
      'lmstudio',
    });
    expect(data.where((quota) => quota.isLocal), hasLength(2));
    expect(data.where((quota) => !quota.isLocal), hasLength(5));

    for (final quota in data) {
      expect(quota.asOf, inInclusiveRange(before, after));
      expect(quota.account, isNotEmpty);
      if (quota.isLocal) {
        expect(quota.active, isTrue);
        expect(quota.details, isNotEmpty);
        expect(quota.windows, isEmpty);
      } else {
        expect(quota.account, 'you@example.com');
        expect(quota.windows, isNotEmpty);
        for (final window in quota.windows) {
          expect(window.usedPercent, inInclusiveRange(0, 100));
          expect(window.resetsAt, greaterThan(before));
        }
      }
    }
  });

  test('demo analytics are bounded, deterministic, and textured', () {
    final first = demoBuckets();
    final second = demoBuckets();

    expect(first.keys, {'claude', 'codex', 'antigravity', 'grok', 'cursor'});
    for (final entry in first.entries) {
      expect(entry.value, hasLength(24 * 40));
      expect(second[entry.key], hasLength(entry.value.length));
      for (var i = 0; i < entry.value.length; i++) {
        final a = entry.value[i];
        final b = second[entry.key]![i];
        expect(a.mean, inInclusiveRange(0, 100));
        expect(b.mean, a.mean);
        expect((a.start - b.start).abs(), lessThanOrEqualTo(1));
      }
    }

    expect(first['claude']!.any((bucket) => bucket.mean == 0), isTrue);
    expect(first['grok']!.any((bucket) => bucket.mean == 0), isTrue);
    expect(first['antigravity']!.any((bucket) => bucket.mean > 90), isTrue);
  });

  test('demo routed-request summary exercises quota and local routes', () {
    final summary = demoRoutedRequestSummary();

    expect(summary.totalRequests, 3);
    expect(summary.routedRequests, 3);
    expect(summary.successfulRequests, 3);
    expect(summary.failedRequests, 0);
    expect(summary.quotaPlanRequests, 2);
    expect(summary.localRequests, 1);
    expect(summary.paidApiRequests, 0);
    expect(summary.totalTokens, 41100);
    expect(summary.topServedModels, hasLength(3));
  });
}
