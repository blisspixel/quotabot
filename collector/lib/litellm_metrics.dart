import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'util.dart';

const litellmMetricsFileName = 'litellm-metrics.jsonl';
const routedRequestSummarySchema = 'quotabot.routed_requests.v1';
const litellmSpendLocal = 'local';
const litellmSpendQuotaPlan = 'quota_plan';
const litellmSpendPaidApi = 'paid_api';
const litellmSpendUnknown = 'unknown';
const litellmEventSuccess = 'success';
const litellmEventFailure = 'failure';
const litellmPipeHealthNoData = 'no_data';
const litellmPipeHealthHealthy = 'healthy';
const litellmPipeHealthThrottled = 'throttled';
const litellmPipeHealthDegraded = 'degraded';

/// The default JSONL file written by the LiteLLM integration. The Python plugin
/// constrains metrics paths to `~/.quotabot`, so the reader uses the same root
/// rather than quotabot's platform-specific config directory.
File defaultLiteLlmMetricsFile() =>
    File('${home()}/.quotabot/$litellmMetricsFileName');

class LiteLlmRouteMetric {
  final int at;
  final String? requestedModel;
  final String? servedModel;
  final int promptTokens;
  final int completionTokens;
  final double cost;
  final String spend;
  final String event;
  final int? httpStatus;
  final int? retryAfterSeconds;
  final int? latencyMs;
  final String? errorType;

  const LiteLlmRouteMetric({
    required this.at,
    required this.requestedModel,
    required this.servedModel,
    required this.promptTokens,
    required this.completionTokens,
    required this.cost,
    this.spend = litellmSpendUnknown,
    this.event = litellmEventSuccess,
    this.httpStatus,
    this.retryAfterSeconds,
    this.latencyMs,
    this.errorType,
  });

  int get totalTokens => promptTokens + completionTokens;

  bool get wasRouted =>
      requestedModel != null &&
      servedModel != null &&
      requestedModel != servedModel;

  String get normalizedSpend => normalizeLiteLlmSpend(spend);
  String get normalizedEvent => normalizeLiteLlmEvent(event);
  bool get failed => normalizedEvent == litellmEventFailure;
  bool get throttled => failed && httpStatus == 429;

  Map<String, dynamic> toJson() => {
        'at': at,
        'event': normalizedEvent,
        if (requestedModel != null) 'requested_model': requestedModel,
        if (servedModel != null) 'served_model': servedModel,
        'spend': normalizedSpend,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'total_tokens': totalTokens,
        'cost': cost,
        'routed': wasRouted,
        if (httpStatus != null) 'http_status': httpStatus,
        if (retryAfterSeconds != null)
          'retry_after_seconds': retryAfterSeconds,
        if (latencyMs != null) 'latency_ms': latencyMs,
        if (errorType != null) 'error_type': errorType,
      };
}

class RoutedModelCount {
  final String model;
  final int count;

  const RoutedModelCount(this.model, this.count);

  Map<String, dynamic> toJson() => {
        'model': model,
        'count': count,
      };
}

class RoutedRequestSummary {
  final int totalRequests;
  final int routedRequests;
  final int successfulRequests;
  final int failedRequests;
  final int throttledRequests;
  final int degradedRequests;
  final int promptTokens;
  final int completionTokens;
  final double cost;
  final int localRequests;
  final int quotaPlanRequests;
  final int paidApiRequests;
  final int unknownSpendRequests;
  final double paidApiCost;
  final int? averageLatencyMs;
  final int? maxRetryAfterSeconds;
  final int? firstAt;
  final int? lastAt;
  final List<RoutedModelCount> topServedModels;

  const RoutedRequestSummary({
    required this.totalRequests,
    required this.routedRequests,
    required this.successfulRequests,
    required this.failedRequests,
    required this.throttledRequests,
    required this.degradedRequests,
    required this.promptTokens,
    required this.completionTokens,
    required this.cost,
    this.localRequests = 0,
    this.quotaPlanRequests = 0,
    this.paidApiRequests = 0,
    this.unknownSpendRequests = 0,
    this.paidApiCost = 0,
    this.averageLatencyMs,
    this.maxRetryAfterSeconds,
    required this.firstAt,
    required this.lastAt,
    required this.topServedModels,
  });

  int get totalTokens => promptTokens + completionTokens;

  bool get hasData => totalRequests > 0;

  String get pipeHealth {
    if (!hasData) return litellmPipeHealthNoData;
    if (throttledRequests > 0) return litellmPipeHealthThrottled;
    if (degradedRequests > 0 || failedRequests > 0) {
      return litellmPipeHealthDegraded;
    }
    return litellmPipeHealthHealthy;
  }

  Map<String, dynamic> toJson() => {
        'schema': routedRequestSummarySchema,
        'total_requests': totalRequests,
        'routed_requests': routedRequests,
        'successful_requests': successfulRequests,
        'failed_requests': failedRequests,
        'throttled_requests': throttledRequests,
        'degraded_requests': degradedRequests,
        'pipe_health': pipeHealth,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'total_tokens': totalTokens,
        'cost': double.parse(cost.toStringAsFixed(6)),
        'local_requests': localRequests,
        'quota_plan_requests': quotaPlanRequests,
        'paid_api_requests': paidApiRequests,
        'unknown_spend_requests': unknownSpendRequests,
        'paid_api_cost': double.parse(paidApiCost.toStringAsFixed(6)),
        if (averageLatencyMs != null)
          'average_latency_ms': averageLatencyMs,
        if (maxRetryAfterSeconds != null)
          'max_retry_after_seconds': maxRetryAfterSeconds,
        if (firstAt != null) 'first_at': firstAt,
        if (lastAt != null) 'last_at': lastAt,
        'top_served_models':
            topServedModels.map((entry) => entry.toJson()).toList(),
      };
}

const emptyRoutedRequestSummary = RoutedRequestSummary(
  totalRequests: 0,
  routedRequests: 0,
  successfulRequests: 0,
  failedRequests: 0,
  throttledRequests: 0,
  degradedRequests: 0,
  promptTokens: 0,
  completionTokens: 0,
  cost: 0,
  firstAt: null,
  lastAt: null,
  topServedModels: [],
);

/// Reads the local LiteLLM routed-request JSONL file and summarizes recent
/// records. The read is bounded to the tail of the file so a long-running proxy
/// cannot make the desktop widget scan an unbounded metrics log on refresh.
RoutedRequestSummary loadRoutedRequestSummary({
  File? file,
  int maxRecords = 5000,
  int maxBytes = 1024 * 1024,
}) {
  final metrics = loadLiteLlmRouteMetrics(
    file: file,
    maxRecords: maxRecords,
    maxBytes: maxBytes,
  );
  return summarizeRoutedRequests(metrics);
}

List<LiteLlmRouteMetric> loadLiteLlmRouteMetrics({
  File? file,
  int maxRecords = 5000,
  int maxBytes = 1024 * 1024,
}) {
  final source = file ?? defaultLiteLlmMetricsFile();
  if (!source.existsSync()) return const [];
  final text = _readTail(source, math.max(1, maxBytes));
  final out = <LiteLlmRouteMetric>[];
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final metric = parseLiteLlmRouteMetric(line);
    if (metric == null) continue;
    out.add(metric);
    if (out.length > maxRecords) out.removeAt(0);
  }
  return out;
}

LiteLlmRouteMetric? parseLiteLlmRouteMetric(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return null;
    final at = _positiveInt(decoded['at']);
    final served = _string(decoded['served_model']);
    final event = normalizeLiteLlmEvent(decoded['event']);
    if (at == null || (served == null && event == litellmEventSuccess)) {
      return null;
    }
    return LiteLlmRouteMetric(
      at: at,
      requestedModel: _string(decoded['requested_model']),
      servedModel: served,
      spend: normalizeLiteLlmSpend(decoded['spend']),
      event: event,
      promptTokens: _nonNegativeInt(decoded['prompt_tokens']) ?? 0,
      completionTokens: _nonNegativeInt(decoded['completion_tokens']) ?? 0,
      cost: _nonNegativeDouble(decoded['cost']) ?? 0,
      httpStatus: _statusCode(decoded['http_status']),
      retryAfterSeconds: _nonNegativeInt(decoded['retry_after_seconds']),
      latencyMs: _nonNegativeInt(decoded['latency_ms']),
      errorType: _string(decoded['error_type']),
    );
  } catch (_) {
    return null;
  }
}

RoutedRequestSummary summarizeRoutedRequests(
  Iterable<LiteLlmRouteMetric> metrics, {
  int topModelLimit = 3,
}) {
  var total = 0;
  var routed = 0;
  var successful = 0;
  var failed = 0;
  var throttled = 0;
  var degraded = 0;
  var prompt = 0;
  var completion = 0;
  var cost = 0.0;
  var local = 0;
  var quotaPlan = 0;
  var paidApi = 0;
  var unknownSpend = 0;
  var paidApiCost = 0.0;
  var latencyTotal = 0;
  var latencySamples = 0;
  int? maxRetryAfter;
  int? first;
  int? last;
  final byModel = <String, int>{};
  for (final metric in metrics) {
    total++;
    if (metric.wasRouted) routed++;
    if (metric.failed) {
      failed++;
      if (metric.throttled) {
        throttled++;
      } else {
        degraded++;
      }
    } else {
      successful++;
    }
    prompt += metric.promptTokens;
    completion += metric.completionTokens;
    cost += metric.cost;
    switch (metric.normalizedSpend) {
      case litellmSpendLocal:
        local++;
        break;
      case litellmSpendQuotaPlan:
        quotaPlan++;
        break;
      case litellmSpendPaidApi:
        paidApi++;
        paidApiCost += metric.cost;
        break;
      default:
        unknownSpend++;
    }
    if (metric.latencyMs != null) {
      latencyTotal += metric.latencyMs!;
      latencySamples++;
    }
    if (metric.retryAfterSeconds != null) {
      final retryAfter = metric.retryAfterSeconds!;
      maxRetryAfter = maxRetryAfter == null
          ? retryAfter
          : math.max(maxRetryAfter, retryAfter).toInt();
    }
    first = first == null ? metric.at : math.min(first, metric.at);
    last = last == null ? metric.at : math.max(last, metric.at);
    final served = metric.servedModel;
    if (!metric.failed && served != null) {
      byModel[served] = (byModel[served] ?? 0) + 1;
    }
  }
  final top = byModel.entries.toList()
    ..sort((a, b) {
      final count = b.value.compareTo(a.value);
      return count == 0 ? a.key.compareTo(b.key) : count;
    });
  return RoutedRequestSummary(
    totalRequests: total,
    routedRequests: routed,
    successfulRequests: successful,
    failedRequests: failed,
    throttledRequests: throttled,
    degradedRequests: degraded,
    promptTokens: prompt,
    completionTokens: completion,
    cost: cost,
    localRequests: local,
    quotaPlanRequests: quotaPlan,
    paidApiRequests: paidApi,
    unknownSpendRequests: unknownSpend,
    paidApiCost: paidApiCost,
    averageLatencyMs:
        latencySamples == 0 ? null : (latencyTotal / latencySamples).round(),
    maxRetryAfterSeconds: maxRetryAfter,
    firstAt: first,
    lastAt: last,
    topServedModels: [
      for (final entry in top.take(topModelLimit))
        RoutedModelCount(entry.key, entry.value),
    ],
  );
}

String normalizeLiteLlmSpend(Object? value) {
  if (value is! String) return litellmSpendUnknown;
  final normalized = value.trim().toLowerCase().replaceAll('-', '_');
  return switch (normalized) {
    'local' || 'free' => litellmSpendLocal,
    'quota' ||
    'quota_plan' ||
    'subscription' ||
    'subscription_quota' =>
      litellmSpendQuotaPlan,
    'paid_api' || 'paid' || 'api' => litellmSpendPaidApi,
    _ => litellmSpendUnknown,
  };
}

String normalizeLiteLlmEvent(Object? value) {
  if (value is! String) return litellmEventSuccess;
  final normalized = value.trim().toLowerCase().replaceAll('-', '_');
  return switch (normalized) {
    'failure' || 'failed' || 'error' => litellmEventFailure,
    _ => litellmEventSuccess,
  };
}

String _readTail(File file, int maxBytes) {
  final length = file.lengthSync();
  if (length <= 0) return '';
  final start = math.max(0, length - maxBytes);
  final raf = file.openSync();
  try {
    raf.setPositionSync(start);
    final bytes = raf.readSync(length - start);
    var text = utf8.decode(bytes, allowMalformed: true);
    if (start > 0) {
      final newline = text.indexOf('\n');
      text = newline < 0 ? '' : text.substring(newline + 1);
    }
    return text;
  } finally {
    raf.closeSync();
  }
}

String? _string(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _positiveInt(Object? value) {
  final parsed = _nonNegativeInt(value);
  return parsed == null || parsed <= 0 ? null : parsed;
}

int? _nonNegativeInt(Object? value) {
  if (value is int && value >= 0) return value;
  if (value is double &&
      value.isFinite &&
      value >= 0 &&
      value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}

double? _nonNegativeDouble(Object? value) {
  if (value is num) {
    final parsed = value.toDouble();
    if (parsed.isFinite && parsed >= 0) return parsed;
  }
  return null;
}

int? _statusCode(Object? value) {
  final parsed = _nonNegativeInt(value);
  if (parsed == null || parsed < 100 || parsed > 599) return null;
  return parsed;
}
