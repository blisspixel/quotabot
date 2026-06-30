import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/litellm_metrics.dart';
import 'package:test/test.dart';

void main() {
  test('parses a LiteLLM routed request metric', () {
    final metric = parseLiteLlmRouteMetric(jsonEncode({
      'at': 1782000000,
      'requested_model': 'frontier-coder',
      'served_model': 'codex-high',
      'prompt_tokens': 1200,
      'completion_tokens': 350,
      'cost': 0.0123,
    }));

    expect(metric, isNotNull);
    expect(metric!.wasRouted, isTrue);
    expect(metric.totalTokens, 1550);
    expect(metric.toJson()['routed'], isTrue);
  });

  test('skips malformed or incomplete metric lines', () {
    expect(parseLiteLlmRouteMetric(''), isNull);
    expect(parseLiteLlmRouteMetric('{not json'), isNull);
    expect(parseLiteLlmRouteMetric('[]'), isNull);
    expect(parseLiteLlmRouteMetric('{"at": 1}'), isNull);
    expect(
        parseLiteLlmRouteMetric('{"at": -1,"served_model":"codex"}'), isNull);
  });

  test('summarizes routed request metrics', () {
    final summary = summarizeRoutedRequests([
      const LiteLlmRouteMetric(
        at: 10,
        requestedModel: 'frontier',
        servedModel: 'codex',
        promptTokens: 100,
        completionTokens: 30,
        cost: 0.01,
      ),
      const LiteLlmRouteMetric(
        at: 20,
        requestedModel: null,
        servedModel: 'codex',
        promptTokens: 50,
        completionTokens: 25,
        cost: 0.02,
      ),
      const LiteLlmRouteMetric(
        at: 15,
        requestedModel: 'bulk',
        servedModel: 'grok',
        promptTokens: 10,
        completionTokens: 5,
        cost: 0,
      ),
    ]);

    expect(summary.totalRequests, 3);
    expect(summary.routedRequests, 2);
    expect(summary.totalTokens, 220);
    expect(summary.cost, closeTo(0.03, 0.000001));
    expect(summary.firstAt, 10);
    expect(summary.lastAt, 20);
    expect(summary.topServedModels.first.model, 'codex');
    expect(summary.topServedModels.first.count, 2);
    expect(summary.toJson()['schema'], routedRequestSummarySchema);
  });

  test('loads only the bounded tail of the metrics file', () {
    final temp =
        Directory.systemTemp.createTempSync('quotabot_litellm_metrics_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final file = File('${temp.path}${Platform.pathSeparator}metrics.jsonl');
    file.writeAsStringSync([
      jsonEncode({
        'at': 1,
        'served_model': 'old',
        'prompt_tokens': 1,
        'padding': 'x'.padRight(400, 'x'),
      }),
      jsonEncode({
        'at': 2,
        'requested_model': 'logical',
        'served_model': 'new',
        'prompt_tokens': 3,
        'completion_tokens': 4,
      }),
    ].join('\n'));

    final all = loadLiteLlmRouteMetrics(file: file, maxBytes: 4096);
    expect(all.map((metric) => metric.servedModel), ['old', 'new']);

    final tail = loadLiteLlmRouteMetrics(file: file, maxBytes: 160);
    expect(tail.map((metric) => metric.servedModel), ['new']);
  });

  test('missing metrics file yields an empty summary', () {
    final summary = loadRoutedRequestSummary(
      file: File('definitely-not-present.jsonl'),
    );

    expect(summary.hasData, isFalse);
    expect(summary.totalRequests, 0);
  });
}
