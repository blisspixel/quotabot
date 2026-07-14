import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'analysis.dart';
import 'cache.dart';
import 'decision.dart';
import 'litellm_metrics.dart';
import 'mcp_http.dart' show isLoopbackMcpHost;
import 'model_catalog.dart';
import 'models.dart';
import 'provider_filters.dart';
import 'registry.dart';
import 'util.dart';

typedef LocalQuotaSnapshotProvider = Future<List<ProviderQuota>> Function();
typedef LocalRoutedRequestSummaryProvider = RoutedRequestSummary Function();

Future<HttpServer> startLocalQuotabotServer({
  int port = 8721,
  InternetAddress? address,
  required LocalQuotaSnapshotProvider snapshotProvider,
  LocalRoutedRequestSummaryProvider routeSummaryProvider =
      loadRoutedRequestSummary,
  int Function() now = nowEpoch,
  void Function(String message)? log,
}) async {
  final bindAddress = address ?? InternetAddress.loopbackIPv4;
  if (!bindAddress.isLoopback) {
    throw ArgumentError.value(
      bindAddress.address,
      'address',
      'local server must bind to a loopback address',
    );
  }
  final server = await HttpServer.bind(bindAddress, port);
  log?.call(
    'quotabot local server listening on http://localhost:${server.port}/',
  );
  log?.call('serves current quota snapshot as JSON on every request');
  log?.call('press ctrl-c to stop\n');

  // Throttle: every endpoint can make authenticated provider calls. Cache the
  // snapshot briefly so a busy local client cannot drive repeated outbound calls
  // and trip provider rate limits.
  List<ProviderQuota>? cached;
  var cachedAt = 0;
  Future<List<ProviderQuota>> snapshot() async {
    final current = now();
    if (cached != null && current - cachedAt < 5) return cached!;
    cached = await snapshotProvider();
    cachedAt = current;
    return cached!;
  }

  void writeJson(HttpRequest req, Object data, [int status = HttpStatus.ok]) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(const JsonEncoder.withIndent('  ').convert(data));
  }

  bool queryFlag(Uri uri, String snakeName, String kebabName) {
    final values = [
      ...?uri.queryParametersAll[snakeName],
      ...?uri.queryParametersAll[kebabName],
    ];
    return values.any((value) {
      final normalized = value.trim().toLowerCase();
      return normalized.isEmpty ||
          normalized == '1' ||
          normalized == 'true' ||
          normalized == 'yes' ||
          normalized == 'on';
    });
  }

  List<String>? queryValues(Uri uri, String snakeName, String kebabName) {
    final values = [
      ...?uri.queryParametersAll[snakeName],
      ...?uri.queryParametersAll[kebabName],
    ];
    return values.isEmpty ? null : values;
  }

  ({double weight, String? error}) queryCostWeight(
    Uri uri,
    bool hasPenalties,
  ) {
    final values = queryValues(uri, 'cost_weight', 'cost-weight');
    if (values == null) return (weight: hasPenalties ? 1.0 : 0.0, error: null);
    final raw = values.last.trim();
    final weight = double.tryParse(raw);
    if (weight == null ||
        !weight.isFinite ||
        weight < 0 ||
        weight > kMaxRoutingCostWeight) {
      return (
        weight: 0.0,
        error: 'cost_weight must be between 0 and 10',
      );
    }
    return (weight: weight, error: null);
  }

  String? queryLast(Uri uri, String snakeName, String kebabName) {
    final values = queryValues(uri, snakeName, kebabName);
    if (values == null) return null;
    final trimmed = values.last.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  ({ModelRequirements? requirements, String? error}) queryRouteRequirements(
    Uri uri,
  ) {
    final hasRequirements = queryLast(uri, 'task', 'task') != null ||
        queryLast(uri, 'min_context', 'min-context') != null ||
        queryFlag(uri, 'require_tools', 'require-tools') ||
        queryFlag(uri, 'require_vision', 'require-vision') ||
        queryFlag(uri, 'require_reasoning', 'require-reasoning') ||
        queryLast(uri, 'tier_floor', 'tier-floor') != null ||
        queryLast(uri, 'tier_ceiling', 'tier-ceiling') != null ||
        queryLast(uri, 'budget', 'budget') != null;
    if (!hasRequirements) return (requirements: null, error: null);
    final rawTask = queryLast(uri, 'task', 'task');
    final rawBudget = queryLast(uri, 'budget', 'budget');
    final budget = rawBudget == null
        ? ModelBudgetPolicy.any
        : modelBudgetPolicyFromName(rawBudget);
    if (budget == null) {
      return (
        requirements: null,
        error: 'unknown budget policy: "$rawBudget"',
      );
    }
    final minContext = int.tryParse(
      queryLast(uri, 'min_context', 'min-context') ?? '',
    );
    final profile = taskProfile(rawTask);
    final explicit = ModelRequirements(
      minContextTokens: minContext == null || minContext <= 0
          ? null
          : minContext.clamp(0, 1 << 31).toInt(),
      requireTools: queryFlag(uri, 'require_tools', 'require-tools'),
      requireVision: queryFlag(uri, 'require_vision', 'require-vision'),
      requireReasoning:
          queryFlag(uri, 'require_reasoning', 'require-reasoning'),
      tierFloor: queryLast(uri, 'tier_floor', 'tier-floor'),
      tierCeiling: queryLast(uri, 'tier_ceiling', 'tier-ceiling'),
      budgetPolicy: budget,
    );
    final parsed = profile.merge(explicit);
    if (parsed.isEmpty && rawBudget == null) {
      return (requirements: null, error: null);
    }
    final requirements = rawBudget == null
        ? const ModelRequirements(budgetPolicy: ModelBudgetPolicy.quota)
            .merge(parsed)
        : parsed;
    return (requirements: requirements, error: null);
  }

  // Answers the /suggest route: parse and validate the routing query, then write
  // the decision. Each validation failure writes a 400 and returns; the caller
  // owns closing the response, so no handler closes it here.
  Future<void> handleSuggest(HttpRequest request) async {
    final exclusions = parseProviderExclusions(
      request.uri.queryParametersAll['exclude'],
    );
    if (!exclusions.ok) {
      writeJson(request, {'error': exclusions.error}, HttpStatus.badRequest);
      return;
    }
    final costPenalties = parseProviderCostPenalties(
      queryValues(request.uri, 'cost_penalty', 'cost-penalty'),
    );
    if (!costPenalties.ok) {
      writeJson(request, {'error': costPenalties.error}, HttpStatus.badRequest);
      return;
    }
    final costWeight = queryCostWeight(
      request.uri,
      costPenalties.penalties.isNotEmpty,
    );
    if (costWeight.error != null) {
      writeJson(request, {'error': costWeight.error}, HttpStatus.badRequest);
      return;
    }
    final routeRequirements = queryRouteRequirements(request.uri);
    if (routeRequirements.error != null) {
      writeJson(
        request,
        {'error': routeRequirements.error},
        HttpStatus.badRequest,
      );
      return;
    }
    final snap =
        filterExcludedProviders(await snapshot(), exclusions.providers);
    final current = now();
    final capabilityGates = providerRouteCapabilityGates(
      snap,
      current,
      catalog: kModelCatalog,
      requirements: routeRequirements.requirements,
    );
    writeJson(
      request,
      decide(
        snap,
        current,
        context: DecisionContext(
          burnStatsByProvider: recentBurnStatsByQuota(snap, current),
          preferLocal: queryFlag(request.uri, 'local_first', 'local-first'),
          costPenaltyByProvider: costPenalties.penalties,
          costWeight: costWeight.weight,
          pipePenaltyByProvider: routeSummaryProvider().pipePenaltyByProvider(
            now: current,
          ),
          capabilityKnownQuotaKeys: capabilityGates.knownQuotaKeys,
          capabilityAvailableQuotaKeys: capabilityGates.availableQuotaKeys,
          capabilityBudgetResetByQuotaKey:
              capabilityGates.budgetResetByQuotaKey,
        ),
      ).route.toJson(),
    );
  }

  // Routes one request to its handler. Handlers only write a response; they
  // never close it, so [serve] can own closing exactly once. A rejected Host or
  // method short-circuits before any snapshot or provider work.
  Future<void> handleRequest(HttpRequest request) async {
    // Reject non-loopback Host headers before doing any work. The socket is
    // already bound to loopback, but a DNS-rebinding page can still reach it as
    // same-origin; the Host check is the fix the MCP HTTP server uses, and this
    // server exposes account identities the same way.
    if (!_isLoopbackHost(request.headers.value('host'))) {
      writeJson(request, {'error': 'forbidden host'}, HttpStatus.forbidden);
      return;
    }
    if (request.method != 'GET') {
      writeJson(
        request,
        {'error': 'method not allowed'},
        HttpStatus.methodNotAllowed,
      );
      return;
    }
    final path = request.uri.path;
    switch (path) {
      case '/':
        final results = await snapshot();
        writeJson(request, {
          'schema': 'quotabot.v1',
          'generated_at': now(),
          'providers': results.map((r) => r.toJson()).toList(),
        });
      case '/suggest':
        await handleSuggest(request);
      case '/health':
        writeJson(request, {'ok': true, 'generated_at': now()});
      default:
        if (path.startsWith('/providers/')) {
          final name = path.substring('/providers/'.length).toLowerCase();
          final match = (await snapshot()).where((r) => r.provider == name);
          if (match.isEmpty) {
            writeJson(
              request,
              {'error': 'unknown provider'},
              HttpStatus.notFound,
            );
          } else {
            writeJson(request, match.first.toJson());
          }
        } else {
          writeJson(request, {'error': 'not found'}, HttpStatus.notFound);
        }
    }
  }

  Future<void> serve() async {
    await for (final request in server) {
      // Every request is answered and its response closed exactly once, here:
      // handlers only write, so no route can leak an open socket or double
      // close. A write or close can itself throw if the client disconnected
      // mid-response; guard both so one ill-timed abort cannot escape this
      // unawaited loop and stop the server draining (a local denial of service).
      try {
        await handleRequest(request);
      } catch (error) {
        // Do not leak internal exception detail to the client.
        log?.call(
          'local server ${request.method} ${request.uri.path} failed: '
          '${error.runtimeType}',
        );
        try {
          writeJson(
            request,
            {'error': 'internal error'},
            HttpStatus.internalServerError,
          );
        } catch (_) {}
      }
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  unawaited(serve());
  return server;
}

/// True when a request's Host header names a loopback host, ignoring the port.
/// A missing Host header (HTTP/1.0, some raw clients) is allowed because the
/// socket already only accepts loopback connections; the guard exists to defeat
/// browser DNS rebinding, which always sends the attacker's Host.
bool _isLoopbackHost(String? host) {
  if (host == null || host.isEmpty) return true;
  var hostname = host.trim();
  if (hostname.startsWith('[')) {
    final close = hostname.indexOf(']');
    if (close < 0) return false;
    hostname = hostname.substring(1, close);
  } else {
    final colon = hostname.indexOf(':');
    if (colon >= 0) hostname = hostname.substring(0, colon);
  }
  return isLoopbackMcpHost(hostname);
}
