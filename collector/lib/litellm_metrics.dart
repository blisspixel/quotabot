import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'util.dart';

const litellmMetricsFileName = 'litellm-metrics.jsonl';
const routedRequestSummarySchema = 'quotabot.routed_requests.v1';

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

  const LiteLlmRouteMetric({
    required this.at,
    required this.requestedModel,
    required this.servedModel,
    required this.promptTokens,
    required this.completionTokens,
    required this.cost,
  });

  int get totalTokens => promptTokens + completionTokens;

  bool get wasRouted =>
      requestedModel != null &&
      servedModel != null &&
      requestedModel != servedModel;

  Map<String, dynamic> toJson() => {
        'at': at,
        if (requestedModel != null) 'requested_model': requestedModel,
        if (servedModel != null) 'served_model': servedModel,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'total_tokens': totalTokens,
        'cost': cost,
        'routed': wasRouted,
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
  final int promptTokens;
  final int completionTokens;
  final double cost;
  final int? firstAt;
  final int? lastAt;
  final List<RoutedModelCount> topServedModels;

  const RoutedRequestSummary({
    required this.totalRequests,
    required this.routedRequests,
    required this.promptTokens,
    required this.completionTokens,
    required this.cost,
    required this.firstAt,
    required this.lastAt,
    required this.topServedModels,
  });

  int get totalTokens => promptTokens + completionTokens;

  bool get hasData => totalRequests > 0;

  Map<String, dynamic> toJson() => {
        'schema': routedRequestSummarySchema,
        'total_requests': totalRequests,
        'routed_requests': routedRequests,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'total_tokens': totalTokens,
        'cost': double.parse(cost.toStringAsFixed(6)),
        if (firstAt != null) 'first_at': firstAt,
        if (lastAt != null) 'last_at': lastAt,
        'top_served_models':
            topServedModels.map((entry) => entry.toJson()).toList(),
      };
}

const emptyRoutedRequestSummary = RoutedRequestSummary(
  totalRequests: 0,
  routedRequests: 0,
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
    if (at == null || served == null) return null;
    return LiteLlmRouteMetric(
      at: at,
      requestedModel: _string(decoded['requested_model']),
      servedModel: served,
      promptTokens: _nonNegativeInt(decoded['prompt_tokens']) ?? 0,
      completionTokens: _nonNegativeInt(decoded['completion_tokens']) ?? 0,
      cost: _nonNegativeDouble(decoded['cost']) ?? 0,
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
  var prompt = 0;
  var completion = 0;
  var cost = 0.0;
  int? first;
  int? last;
  final byModel = <String, int>{};
  for (final metric in metrics) {
    total++;
    if (metric.wasRouted) routed++;
    prompt += metric.promptTokens;
    completion += metric.completionTokens;
    cost += metric.cost;
    first = first == null ? metric.at : math.min(first, metric.at);
    last = last == null ? metric.at : math.max(last, metric.at);
    final served = metric.servedModel;
    if (served != null) byModel[served] = (byModel[served] ?? 0) + 1;
  }
  final top = byModel.entries.toList()
    ..sort((a, b) {
      final count = b.value.compareTo(a.value);
      return count == 0 ? a.key.compareTo(b.key) : count;
    });
  return RoutedRequestSummary(
    totalRequests: total,
    routedRequests: routed,
    promptTokens: prompt,
    completionTokens: completion,
    cost: cost,
    firstAt: first,
    lastAt: last,
    topServedModels: [
      for (final entry in top.take(topModelLimit))
        RoutedModelCount(entry.key, entry.value),
    ],
  );
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
