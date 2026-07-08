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
      'spend': 'quota-plan',
      'prompt_tokens': 1200,
      'completion_tokens': 350,
      'cost': 0.0123,
    }));

    expect(metric, isNotNull);
    expect(metric!.wasRouted, isTrue);
    expect(metric.event, litellmEventSuccess);
    expect(metric.spend, litellmSpendQuotaPlan);
    expect(metric.totalTokens, 1550);
    expect(metric.toJson()['routed'], isTrue);
    expect(metric.toJson()['spend'], litellmSpendQuotaPlan);
    expect(metric.toJson()['event'], litellmEventSuccess);
  });

  test('parses LiteLLM failure pipe-health metadata', () {
    final metric = parseLiteLlmRouteMetric(jsonEncode({
      'at': 1782000000,
      'event': 'failure',
      'requested_model': 'frontier-coder',
      'served_model': 'claude-sonnet',
      'spend': 'quota_plan',
      'http_status': 429,
      'retry_after_seconds': 90,
      'latency_ms': 1234,
      'error_type': 'RateLimitError',
    }));

    expect(metric, isNotNull);
    expect(metric!.failed, isTrue);
    expect(metric.throttled, isTrue);
    expect(metric.httpStatus, 429);
    expect(metric.retryAfterSeconds, 90);
    expect(metric.latencyMs, 1234);
    expect(metric.errorType, 'RateLimitError');
    expect(metric.toJson()['event'], litellmEventFailure);
    expect(metric.toJson()['http_status'], 429);
  });

  test('keeps failure records even when served model is absent', () {
    final metric = parseLiteLlmRouteMetric(jsonEncode({
      'at': 1782000000,
      'event': 'failure',
      'http_status': 529,
    }));

    expect(metric, isNotNull);
    expect(metric!.failed, isTrue);
    expect(metric.servedModel, isNull);
  });

  test('normalizes absent or malformed LiteLLM spend labels to unknown', () {
    final metric = parseLiteLlmRouteMetric(jsonEncode({
      'at': 1782000000,
      'served_model': 'codex-high',
      'spend': 'not-a-spend-class',
    }));

    expect(metric, isNotNull);
    expect(metric!.spend, litellmSpendUnknown);
    expect(normalizeLiteLlmEvent('error'), litellmEventFailure);
    expect(normalizeLiteLlmEvent('anything-else'), litellmEventSuccess);
    expect(normalizeLiteLlmSpend('subscription'), litellmSpendQuotaPlan);
    expect(normalizeLiteLlmSpend('free'), litellmSpendLocal);
    expect(normalizeLiteLlmSpend('api'), litellmSpendPaidApi);
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
        spend: litellmSpendQuotaPlan,
        promptTokens: 100,
        completionTokens: 30,
        cost: 0.01,
        latencyMs: 100,
      ),
      const LiteLlmRouteMetric(
        at: 20,
        requestedModel: null,
        servedModel: 'codex',
        spend: litellmSpendPaidApi,
        promptTokens: 50,
        completionTokens: 25,
        cost: 0.02,
        latencyMs: 300,
      ),
      const LiteLlmRouteMetric(
        at: 15,
        requestedModel: 'bulk',
        servedModel: 'grok',
        spend: litellmSpendLocal,
        promptTokens: 10,
        completionTokens: 5,
        cost: 0,
        event: litellmEventFailure,
        httpStatus: 429,
        retryAfterSeconds: 120,
        latencyMs: 200,
      ),
    ]);

    expect(summary.totalRequests, 3);
    expect(summary.routedRequests, 2);
    expect(summary.successfulRequests, 2);
    expect(summary.failedRequests, 1);
    expect(summary.throttledRequests, 1);
    expect(summary.degradedRequests, 0);
    expect(summary.pipeHealth, litellmPipeHealthThrottled);
    expect(summary.totalTokens, 220);
    expect(summary.cost, closeTo(0.03, 0.000001));
    expect(summary.localRequests, 1);
    expect(summary.quotaPlanRequests, 1);
    expect(summary.paidApiRequests, 1);
    expect(summary.unknownSpendRequests, 0);
    expect(summary.paidApiCost, closeTo(0.02, 0.000001));
    expect(summary.firstAt, 10);
    expect(summary.lastAt, 20);
    expect(summary.averageLatencyMs, 200);
    expect(summary.maxRetryAfterSeconds, 120);
    expect(summary.topServedModels.first.model, 'codex');
    expect(summary.topServedModels.first.count, 2);
    expect(
      summary.topServedModels.any((entry) => entry.model == 'grok'),
      isFalse,
    );
    expect(summary.toJson()['schema'], routedRequestSummarySchema);
    expect(summary.toJson()['paid_api_requests'], 1);
    expect(summary.toJson()['paid_api_cost'], 0.02);
    expect(summary.toJson()['pipe_health'], litellmPipeHealthThrottled);
    expect(summary.toJson()['average_latency_ms'], 200);
    expect(summary.toJson()['max_retry_after_seconds'], 120);
  });

  test('classifies non-throttle failures as degraded pipe health', () {
    final summary = summarizeRoutedRequests([
      const LiteLlmRouteMetric(
        at: 10,
        requestedModel: 'frontier',
        servedModel: 'claude',
        promptTokens: 0,
        completionTokens: 0,
        cost: 0,
        event: litellmEventFailure,
        httpStatus: 529,
      ),
    ]);

    expect(summary.pipeHealth, litellmPipeHealthDegraded);
    expect(summary.failedRequests, 1);
    expect(summary.degradedRequests, 1);
    expect(summary.throttledRequests, 0);
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
    expect(summary.pipeHealth, litellmPipeHealthNoData);
  });
}
