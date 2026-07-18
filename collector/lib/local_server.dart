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
  Future<List<ProviderQuota>>? inFlightSnapshot;
  Future<List<ProviderQuota>> snapshot() async {
    final current = now();
    if (cached != null && current - cachedAt < 5) return cached!;
    final active = inFlightSnapshot;
    if (active != null) return active;

    // Schedule collection after publishing the in-flight future. This keeps a
    // reentrant or concurrently dispatched request from starting a duplicate
    // provider read before the throttle has a result to cache.
    final requested = Future<List<ProviderQuota>>.microtask(snapshotProvider);
    inFlightSnapshot = requested;
    try {
      final fresh = await requested;
      cached = fresh;
      // Cache age begins when collection finishes, not when it starts. A slow
      // provider read should not make its result stale before it is returned.
      cachedAt = now();
      return fresh;
    } finally {
      if (identical(inFlightSnapshot, requested)) {
        inFlightSnapshot = null;
      }
    }
  }

  void writeJson(HttpRequest req, Object data, [int status = HttpStatus.ok]) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(const JsonEncoder.withIndent('  ').convert(data));
  }

  List<String>? queryValues(Uri uri, String snakeName, String kebabName) {
    final values = snakeName == kebabName
        ? [...?uri.queryParametersAll[snakeName]]
        : [
            ...?uri.queryParametersAll[snakeName],
            ...?uri.queryParametersAll[kebabName],
          ];
    return values.isEmpty ? null : values;
  }

  ({bool value, String? error}) queryBoolean(
    Uri uri,
    String snakeName,
    String kebabName,
  ) {
    final values = queryValues(uri, snakeName, kebabName);
    if (values == null) return (value: false, error: null);
    final normalized = values.last.trim().toLowerCase();
    if (normalized.isEmpty ||
        normalized == '1' ||
        normalized == 'true' ||
        normalized == 'yes' ||
        normalized == 'on') {
      return (value: true, error: null);
    }
    if (normalized == '0' ||
        normalized == 'false' ||
        normalized == 'no' ||
        normalized == 'off') {
      return (value: false, error: null);
    }
    return (value: false, error: '$snakeName must be a boolean');
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

  ({ModelRequirements? requirements, String? error}) queryRouteRequirements(
    Uri uri,
  ) {
    final taskValues = queryValues(uri, 'task', 'task');
    final contextValues = queryValues(uri, 'min_context', 'min-context');
    final tierFloorValues = queryValues(uri, 'tier_floor', 'tier-floor');
    final tierCeilingValues = queryValues(uri, 'tier_ceiling', 'tier-ceiling');
    final budgetValues = queryValues(uri, 'budget', 'budget');
    final tools = queryBoolean(uri, 'require_tools', 'require-tools');
    final vision = queryBoolean(uri, 'require_vision', 'require-vision');
    final reasoning =
        queryBoolean(uri, 'require_reasoning', 'require-reasoning');
    for (final flag in [tools, vision, reasoning]) {
      if (flag.error != null) {
        return (requirements: null, error: flag.error);
      }
    }
    final hasRequirements = taskValues != null ||
        contextValues != null ||
        tools.value ||
        vision.value ||
        reasoning.value ||
        tierFloorValues != null ||
        tierCeilingValues != null ||
        budgetValues != null;
    if (!hasRequirements) return (requirements: null, error: null);
    final rawTask = taskValues?.last.trim().toLowerCase();
    const taskChoices = {'simple', 'standard', 'hard', 'complex', 'reasoning'};
    if (rawTask != null && !taskChoices.contains(rawTask)) {
      return (requirements: null, error: 'unknown task profile: "$rawTask"');
    }
    final rawBudget = budgetValues?.last.trim().toLowerCase();
    if (rawBudget != null && rawBudget.isEmpty) {
      return (requirements: null, error: 'unknown budget policy: ""');
    }
    final budget = rawBudget == null
        ? ModelBudgetPolicy.any
        : modelBudgetPolicyFromName(rawBudget);
    if (budget == null) {
      return (
        requirements: null,
        error: 'unknown budget policy: "$rawBudget"',
      );
    }
    final rawContext = contextValues?.last.trim();
    final minContext = rawContext == null ? null : int.tryParse(rawContext);
    if (rawContext != null &&
        (minContext == null || minContext <= 0 || minContext > 1 << 31)) {
      return (
        requirements: null,
        error: 'min_context must be a positive integer up to ${1 << 31}',
      );
    }
    const tierRanks = {'light': 0, 'standard': 1, 'flagship': 2};
    final tierFloor = tierFloorValues?.last.trim().toLowerCase();
    final tierCeiling = tierCeilingValues?.last.trim().toLowerCase();
    if (tierFloor != null && !tierRanks.containsKey(tierFloor)) {
      return (requirements: null, error: 'unknown tier_floor: "$tierFloor"');
    }
    if (tierCeiling != null && !tierRanks.containsKey(tierCeiling)) {
      return (
        requirements: null,
        error: 'unknown tier_ceiling: "$tierCeiling"'
      );
    }
    if (tierFloor != null &&
        tierCeiling != null &&
        tierRanks[tierFloor]! > tierRanks[tierCeiling]!) {
      return (
        requirements: null,
        error: 'tier_floor cannot be higher than tier_ceiling',
      );
    }
    final profile = taskProfile(rawTask);
    final explicit = ModelRequirements(
      minContextTokens: minContext,
      requireTools: tools.value,
      requireVision: vision.value,
      requireReasoning: reasoning.value,
      tierFloor: tierFloor,
      tierCeiling: tierCeiling,
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
    const allowedQueryParameters = {
      'exclude',
      'cost_penalty',
      'cost-penalty',
      'cost_weight',
      'cost-weight',
      'task',
      'min_context',
      'min-context',
      'require_tools',
      'require-tools',
      'require_vision',
      'require-vision',
      'require_reasoning',
      'require-reasoning',
      'tier_floor',
      'tier-floor',
      'tier_ceiling',
      'tier-ceiling',
      'budget',
      'local_first',
      'local-first',
    };
    final unknownParameters = request.uri.queryParametersAll.keys
        .where((name) => !allowedQueryParameters.contains(name))
        .toList()
      ..sort();
    if (unknownParameters.isNotEmpty) {
      writeJson(
        request,
        {
          'error': 'unknown query parameter: ${unknownParameters.join(', ')}',
        },
        HttpStatus.badRequest,
      );
      return;
    }
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
    final localFirst = queryBoolean(
      request.uri,
      'local_first',
      'local-first',
    );
    if (localFirst.error != null) {
      writeJson(
        request,
        {'error': localFirst.error},
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
          preferLocal: localFirst.value,
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
