import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'analysis.dart';
import 'cache.dart';
import 'decision.dart';
import 'leases.dart';
import 'litellm_metrics.dart';
import 'local_http_auth.dart';
import 'mcp_http.dart' show isLoopbackMcpHost;
import 'model_catalog.dart';
import 'models.dart';
import 'provider_filters.dart';
import 'registry.dart';
import 'routing_context.dart';
import 'util.dart';

typedef LocalQuotaSnapshotProvider = Future<List<ProviderQuota>> Function();
typedef LocalRoutedRequestSummaryProvider = RoutedRequestSummary Function();

const _maxLocalMutationBodyBytes = 32 * 1024;
const _maxLocalMutationDrainBytes = 64 * 1024;
const _maxLocalMutationTargets = 64;
final _localLeaseIdPattern = RegExp(r'^[A-Za-z0-9_-]{8,96}$');
final _localLeaseProviderPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final _localLeaseIdempotencyPattern = RegExp(r'^[A-Za-z0-9_-]{8,120}$');

class _LocalLeaseTarget {
  final String provider;
  final String? account;

  const _LocalLeaseTarget(this.provider, this.account);
}

class _LocalReserveRequest {
  final List<_LocalLeaseTarget> targets;
  final double minimumEffectiveHeadroom;
  final int leaseSeconds;
  final double weightPercent;
  final String? client;
  final String? idempotencyKey;

  const _LocalReserveRequest({
    required this.targets,
    required this.minimumEffectiveHeadroom,
    required this.leaseSeconds,
    required this.weightPercent,
    required this.client,
    required this.idempotencyKey,
  });
}

Future<HttpServer> startLocalQuotabotServer({
  int port = 8721,
  InternetAddress? address,
  required LocalQuotaSnapshotProvider snapshotProvider,
  LocalRoutedRequestSummaryProvider routeSummaryProvider =
      loadRoutedRequestSummary,
  RouteLeaseStore leaseStore = const NoopRouteLeaseStore(),
  String? mutationToken,
  int maxConcurrentRequests = 32,
  int Function() now = nowEpoch,
  void Function(String message)? log,
}) async {
  if (maxConcurrentRequests < 1) {
    throw ArgumentError.value(
      maxConcurrentRequests,
      'maxConcurrentRequests',
      'must be at least 1',
    );
  }
  if (mutationToken != null && !isValidLocalHttpMutationToken(mutationToken)) {
    throw ArgumentError.value(
      mutationToken.length,
      'mutationToken',
      'must be a 32..128 character base64url token',
    );
  }
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
  log?.call('serves current quota snapshot and routing metadata as JSON');
  if (mutationToken != null) {
    log?.call('authenticated loopback lease mutations are enabled');
  }
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
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..write(const JsonEncoder.withIndent('  ').convert(data));
  }

  bool constantTimeEquals(String actual, String expected) {
    final left = utf8.encode(actual);
    final right = utf8.encode(expected);
    final length = left.length > right.length ? left.length : right.length;
    var difference = left.length ^ right.length;
    for (var i = 0; i < length; i++) {
      final leftByte = i < left.length ? left[i] : 0;
      final rightByte = i < right.length ? right[i] : 0;
      difference |= leftByte ^ rightByte;
    }
    return difference == 0;
  }

  bool authorizedMutation(HttpRequest request) {
    final token = mutationToken;
    if (token == null) return false;
    final values = request.headers[HttpHeaders.authorizationHeader];
    if (values == null || values.length != 1) return false;
    return constantTimeEquals(values.single, 'Bearer $token');
  }

  Future<({Map<String, dynamic>? body, String? error, int status})>
      readMutationBody(HttpRequest request) async {
    final contentType = request.headers.contentType;
    if (contentType == null ||
        contentType.mimeType.toLowerCase() != 'application/json') {
      return (
        body: null,
        error: 'content type must be application/json',
        status: 415,
      );
    }
    final declaredLength = request.contentLength;
    if (declaredLength > _maxLocalMutationBodyBytes) {
      if (declaredLength <= _maxLocalMutationDrainBytes) {
        await request.drain<void>();
      } else {
        request.response.headers.set(HttpHeaders.connectionHeader, 'close');
      }
      return (body: null, error: 'request body too large', status: 413);
    }
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    var tooLarge = false;
    try {
      await for (final chunk in request) {
        total += chunk.length;
        if (total > _maxLocalMutationBodyBytes) {
          tooLarge = true;
          if (total > _maxLocalMutationDrainBytes) {
            request.response.headers.set(HttpHeaders.connectionHeader, 'close');
            return (body: null, error: 'request body too large', status: 413);
          }
          continue;
        }
        if (!tooLarge) bytes.add(chunk);
      }
      if (tooLarge) {
        return (body: null, error: 'request body too large', status: 413);
      }
      if (total == 0) {
        return (body: null, error: 'request body is required', status: 400);
      }
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
        return (
          body: null,
          error: 'request body must be an object',
          status: 400
        );
      }
      return (
        body: Map<String, dynamic>.from(decoded),
        error: null,
        status: 200,
      );
    } on FormatException {
      return (
        body: null,
        error: 'request body must be valid JSON',
        status: 400
      );
    }
  }

  String? rejectUnknownFields(
    Map<String, dynamic> body,
    Set<String> allowed,
  ) {
    final unknown = body.keys.where((key) => !allowed.contains(key)).toList()
      ..sort();
    return unknown.isEmpty ? null : 'unknown field: ${unknown.join(', ')}';
  }

  ({_LocalReserveRequest? request, String? error}) parseReserveRequest(
    Map<String, dynamic> body,
  ) {
    final unknown = rejectUnknownFields(body, const {
      'targets',
      'minimum_effective_headroom',
      'lease_seconds',
      'weight_percent',
      'client',
      'idempotency_key',
    });
    if (unknown != null) return (request: null, error: unknown);

    final rawTargets = body['targets'];
    if (rawTargets is! List ||
        rawTargets.isEmpty ||
        rawTargets.length > _maxLocalMutationTargets) {
      return (
        request: null,
        error: 'targets must contain 1..$_maxLocalMutationTargets entries',
      );
    }
    final targets = <_LocalLeaseTarget>[];
    final seenTargets = <String>{};
    for (final rawTarget in rawTargets) {
      if (rawTarget is! Map || rawTarget.keys.any((key) => key is! String)) {
        return (request: null, error: 'each target must be an object');
      }
      final target = Map<String, dynamic>.from(rawTarget);
      final targetUnknown = rejectUnknownFields(
        target,
        const {'provider', 'account'},
      );
      if (targetUnknown != null) return (request: null, error: targetUnknown);
      final rawProvider = target['provider'];
      if (rawProvider is! String ||
          !_localLeaseProviderPattern.hasMatch(rawProvider)) {
        return (request: null, error: 'target provider is invalid');
      }
      final provider = normalizeLeaseProvider(rawProvider);
      final rawAccount = target['account'];
      String? account;
      if (rawAccount != null) {
        if (rawAccount is! String ||
            rawAccount != rawAccount.trim() ||
            rawAccount.isEmpty ||
            rawAccount.length > 256 ||
            _containsControlCharacters(rawAccount)) {
          return (request: null, error: 'target account is invalid');
        }
        account = normalizeLeaseAccount(rawAccount);
      }
      final identity = '$provider\u0000${account ?? '*'}';
      if (seenTargets.add(identity)) {
        targets.add(_LocalLeaseTarget(provider, account));
      }
    }

    final rawMinimum = body['minimum_effective_headroom'];
    final minimum = rawMinimum == null ? 0.5 : _finiteDouble(rawMinimum);
    if (minimum == null || minimum < 0 || minimum > 100) {
      return (
        request: null,
        error: 'minimum_effective_headroom must be between 0 and 100',
      );
    }
    final rawSeconds = body['lease_seconds'];
    final seconds =
        rawSeconds == null ? defaultLeaseSeconds : _exactInteger(rawSeconds);
    if (seconds == null ||
        seconds < minLeaseSeconds ||
        seconds > maxLeaseSeconds) {
      return (
        request: null,
        error: 'lease_seconds must be between 15 and 3600',
      );
    }
    final rawWeight = body['weight_percent'];
    final weight = rawWeight == null
        ? defaultLeaseWeightPercent
        : _finiteDouble(rawWeight);
    if (weight == null ||
        weight < minLeaseWeightPercent ||
        weight > maxLeaseWeightPercent) {
      return (
        request: null,
        error: 'weight_percent must be between 1 and 50',
      );
    }
    final rawClient = body['client'];
    final client = rawClient == null
        ? null
        : normalizeLeaseText(rawClient, maxLength: 120);
    if (rawClient != null &&
        (rawClient is! String ||
            rawClient != rawClient.trim() ||
            client == null ||
            client.length != rawClient.length ||
            _containsControlCharacters(rawClient))) {
      return (request: null, error: 'client is invalid');
    }
    final rawIdempotency = body['idempotency_key'];
    final idempotency =
        rawIdempotency == null ? null : rawIdempotency as Object?;
    if (idempotency != null &&
        (idempotency is! String ||
            !_localLeaseIdempotencyPattern.hasMatch(idempotency))) {
      return (request: null, error: 'idempotency_key is invalid');
    }

    return (
      request: _LocalReserveRequest(
        targets: List.unmodifiable(targets),
        minimumEffectiveHeadroom: minimum,
        leaseSeconds: seconds,
        weightPercent: weight,
        client: client,
        idempotencyKey: idempotency as String?,
      ),
      error: null,
    );
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

  List<Map<String, dynamic>> activeLeaseJson(List<RouteLease> leases) =>
      leaseDiscounts(leases)
          .map((discount) => discount.toJson())
          .toList(growable: false);

  Future<void> handleReserveMutation(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final parsed = parseReserveRequest(body);
    if (parsed.error != null) {
      writeJson(request, {'error': parsed.error}, HttpStatus.badRequest);
      return;
    }
    final reserveRequest = parsed.request!;
    final collected = await snapshot();
    // Collection can involve bounded provider metadata calls. Timestamp the
    // decision and TTL after it completes so a slow read cannot create a lease
    // that is already partly or fully expired when returned.
    final current = now();
    final candidates = collected
        .where((quota) =>
            !quota.isLocal &&
            _matchesLocalLeaseTarget(quota, reserveRequest.targets))
        .toList(growable: false);
    if (candidates.isEmpty) {
      final active = leaseStore.active(current);
      writeJson(request, {
        'schema': 'quotabot.reserve.v1',
        'as_of': current,
        'reserved': false,
        'reused': false,
        'reason': 'no requested provider account is available',
        'lease': null,
        'selected': null,
        'active_leases': activeLeaseJson(active),
      });
      return;
    }

    final burnStats = recentBurnStatsByQuota(candidates, current);
    final pipePenalties = routeSummaryProvider().pipePenaltyByProvider(
      now: current,
    );
    Decision evaluate(List<RouteLease> activeLeases) => decide(
          candidates,
          current,
          context: providerRouteDecisionContext(
            candidates,
            current,
            comfortThreshold: reserveRequest.minimumEffectiveHeadroom,
            burnStatsByProvider: burnStats,
            activeLeases: activeLeases,
            pipePenaltyByProvider: pipePenalties,
            catalog: kModelCatalog,
          ),
        );

    RouteCandidate? selected;
    RouteSuggestion? selectionRoute;
    final reservation = leaseStore.selectAndReserve(
      select: (activeLeases) {
        final route = evaluate(activeLeases).route;
        final target = route.recommended;
        if (target == null) {
          return const RouteLeaseSelection.unavailable(
            'no reservable provider available',
          );
        }
        final effective = target.effectiveHeadroom;
        if (target.isLocal ||
            !target.available ||
            effective == null ||
            effective <= kSpentHeadroomFloor ||
            effective < reserveRequest.minimumEffectiveHeadroom) {
          return const RouteLeaseSelection.unavailable(
            'no requested provider has enough effective headroom',
          );
        }
        selected = target;
        selectionRoute = route;
        return RouteLeaseSelection.selected(
          RouteLeaseTarget(
            provider: target.provider,
            account: target.account,
          ),
        );
      },
      now: current,
      leaseSeconds: reserveRequest.leaseSeconds,
      weightPercent: reserveRequest.weightPercent,
      client: reserveRequest.client,
      idempotencyKey: reserveRequest.idempotencyKey,
      reuseWhere: (lease) => candidates.any(
        (quota) =>
            normalizeLeaseProvider(quota.provider) == lease.provider &&
            normalizeLeaseAccount(quota.account) == lease.account,
      ),
    );

    final lease = reservation.lease;
    if (reservation.reserved && lease != null) {
      if (selected == null || !_routeCandidateMatchesLease(selected!, lease)) {
        final beforeThisLease = reservation.activeLeases
            .where((active) => active.id != lease.id)
            .toList(growable: false);
        final route = evaluate(beforeThisLease).route;
        for (final candidate in route.ranked) {
          if (_routeCandidateMatchesLease(candidate, lease)) {
            selected = candidate;
            selectionRoute = route;
            break;
          }
        }
      }
      if (selected == null && !reservation.reused) {
        final released = leaseStore.release(leaseId: lease.id, now: current);
        writeJson(request, {
          'schema': 'quotabot.reserve.v1',
          'as_of': current,
          'reserved': false,
          'reused': false,
          'reason': 'reserved target could not be verified',
          'lease': null,
          'selected': null,
          'active_leases': activeLeaseJson(released.activeLeases),
        });
        return;
      }
    }

    writeJson(request, {
      'schema': 'quotabot.reserve.v1',
      'as_of': current,
      'reserved': reservation.reserved && selected != null,
      'reused': reservation.reused,
      'reason': reservation.reason,
      'lease': reservation.lease?.toJson(),
      'selected': selected?.toJson(),
      if (selectionRoute != null)
        'decision_id': selectionRoute!.receipt.decisionId,
      'active_leases': activeLeaseJson(reservation.activeLeases),
    });
  }

  void handleReleaseMutation(
    HttpRequest request,
    Map<String, dynamic> body,
  ) {
    final unknown = rejectUnknownFields(body, const {'lease_id'});
    final rawLeaseId = body['lease_id'];
    if (unknown != null ||
        rawLeaseId is! String ||
        !_localLeaseIdPattern.hasMatch(rawLeaseId)) {
      writeJson(
        request,
        {'error': unknown ?? 'lease_id is invalid'},
        HttpStatus.badRequest,
      );
      return;
    }
    final current = now();
    final release = leaseStore.release(leaseId: rawLeaseId, now: current);
    writeJson(request, {
      'schema': 'quotabot.release.v1',
      'as_of': current,
      'released': release.released,
      'reason': release.reason,
      'lease_id': rawLeaseId,
      'lease': release.lease?.toJson(),
      'active_leases': activeLeaseJson(release.activeLeases),
    });
  }

  Future<void> handleMutation(HttpRequest request) async {
    if (!authorizedMutation(request)) {
      request.response.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Bearer realm="quotabot-local"',
      );
      writeJson(request, {'error': 'unauthorized'}, HttpStatus.unauthorized);
      return;
    }
    if (request.uri.hasQuery) {
      writeJson(
        request,
        {'error': 'query parameters are not allowed'},
        HttpStatus.badRequest,
      );
      return;
    }
    final decoded = await readMutationBody(request);
    if (decoded.error != null) {
      writeJson(request, {'error': decoded.error}, decoded.status);
      return;
    }
    switch (request.uri.path) {
      case '/leases/reserve':
        await handleReserveMutation(request, decoded.body!);
      case '/leases/release':
        handleReleaseMutation(request, decoded.body!);
    }
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
    final activeLeases = leaseStore.active(current);
    writeJson(
      request,
      decide(
        snap,
        current,
        context: providerRouteDecisionContext(
          snap,
          current,
          burnStatsByProvider: recentBurnStatsByQuota(snap, current),
          activeLeases: activeLeases,
          preferLocal: localFirst.value,
          costPenaltyByProvider: costPenalties.penalties,
          costWeight: costWeight.weight,
          pipePenaltyByProvider: routeSummaryProvider().pipePenaltyByProvider(
            now: current,
          ),
          catalog: kModelCatalog,
          routeRequirements: routeRequirements.requirements,
        ),
      ).route.toJson(),
    );
  }

  // Routes one request to its handler. Handlers only write a response; they
  // never close it, so [serve] can own closing exactly once. A rejected Host or
  // method short-circuits before any snapshot or provider work.
  Future<void> handleRequest(HttpRequest request) async {
    // Reject unsafe browser authority, Origin, and Fetch Metadata before doing
    // any provider work. Host blocks DNS rebinding. Origin and Sec-Fetch-Site
    // block a public web page from making a blind cross-origin subresource
    // request that triggers collection or cache writes even though CORS keeps
    // it from reading the response.
    if (!_isLoopbackHost(request.headers.value('host'))) {
      writeJson(request, {'error': 'forbidden host'}, HttpStatus.forbidden);
      return;
    }
    final origins = request.headers['origin'];
    if (origins != null &&
        (origins.length != 1 || !_isLoopbackOrigin(origins.single))) {
      writeJson(request, {'error': 'forbidden origin'}, HttpStatus.forbidden);
      return;
    }
    if (origins == null && !_allowsOriginlessFetchMetadata(request.headers)) {
      writeJson(
        request,
        {'error': 'forbidden fetch metadata'},
        HttpStatus.forbidden,
      );
      return;
    }
    final path = request.uri.path;
    final mutationPath = path == '/leases/reserve' || path == '/leases/release';
    if (mutationPath) {
      if (mutationToken == null) {
        writeJson(request, {'error': 'not found'}, HttpStatus.notFound);
        return;
      }
      if (request.method != 'POST') {
        request.response.headers.set(HttpHeaders.allowHeader, 'POST');
        writeJson(
          request,
          {'error': 'method not allowed'},
          HttpStatus.methodNotAllowed,
        );
        return;
      }
      await handleMutation(request);
      return;
    }
    if (request.method != 'GET') {
      request.response.headers.set(HttpHeaders.allowHeader, 'GET');
      writeJson(
        request,
        {'error': 'method not allowed'},
        HttpStatus.methodNotAllowed,
      );
      return;
    }
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
          final match = bestProviderAccountForCheck(
            (await snapshot()).where((r) => r.provider == name),
            now(),
          );
          if (match == null) {
            writeJson(
              request,
              {'error': 'unknown provider'},
              HttpStatus.notFound,
            );
          } else {
            writeJson(request, match.toJson());
          }
        } else {
          writeJson(request, {'error': 'not found'}, HttpStatus.notFound);
        }
    }
  }

  Future<void> process(HttpRequest request) async {
    // Every request is answered and its response closed exactly once, here:
    // handlers only write, so no route can leak an open socket or double
    // close. A write or close can itself throw if the client disconnected
    // mid-response; guard both so one ill-timed abort cannot stop the server.
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

  Future<void> serve() async {
    var activeRequests = 0;
    await for (final request in server) {
      if (activeRequests >= maxConcurrentRequests) {
        try {
          request.response.headers
            ..set(HttpHeaders.retryAfterHeader, '1')
            ..set(HttpHeaders.connectionHeader, 'close');
          writeJson(
            request,
            {'error': 'server busy'},
            HttpStatus.serviceUnavailable,
          );
          await request.response.close();
        } catch (_) {}
        continue;
      }
      // Do not let a slow provider metadata read head-of-line block /health or
      // unrelated clients. Snapshot-backed routes still share the single
      // in-flight collection above, so concurrency cannot multiply provider
      // calls during the throttle window. The active limit bounds pending
      // response futures if clients or a provider read stall.
      activeRequests++;
      unawaited(process(request).whenComplete(() => activeRequests--));
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
    final suffix = hostname.substring(close + 1);
    if (suffix.isNotEmpty && !_isValidHostPort(suffix)) return false;
    hostname = hostname.substring(1, close);
  } else {
    final firstColon = hostname.indexOf(':');
    if (firstColon >= 0) {
      if (hostname.indexOf(':', firstColon + 1) >= 0) return false;
      final suffix = hostname.substring(firstColon);
      if (!_isValidHostPort(suffix)) return false;
      hostname = hostname.substring(0, firstColon);
    }
  }
  return isLoopbackMcpHost(hostname);
}

bool _isValidHostPort(String suffix) {
  if (!suffix.startsWith(':')) return false;
  final rawPort = suffix.substring(1);
  if (!RegExp(r'^[0-9]+$').hasMatch(rawPort)) return false;
  final port = int.tryParse(rawPort);
  return port != null && port >= 1 && port <= 65535;
}

bool _isLoopbackOrigin(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return false;
  }
  if (!uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.path.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }
  try {
    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) return false;
  } on FormatException {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost') return true;
  final address = InternetAddress.tryParse(host);
  if (address == null) return false;
  return switch (address.type) {
    InternetAddressType.IPv4 => address.address.startsWith('127.'),
    InternetAddressType.IPv6 => address.address == '::1',
    _ => false,
  };
}

bool _allowsOriginlessFetchMetadata(HttpHeaders headers) {
  final site = _singleFetchMetadataValue(headers, 'sec-fetch-site');
  if (site == null) {
    // Non-browser clients do not send Fetch Metadata. The loopback socket and
    // Host guard remain the authority boundary for those clients.
    return headers['sec-fetch-site'] == null;
  }
  if (site == 'same-origin' || site == 'none') return true;
  if (site != 'same-site' && site != 'cross-site') return false;

  // Preserve an explicit user-activated top-level navigation. Subresources,
  // scripts, and automatic navigations do not carry this complete tuple.
  return _singleFetchMetadataValue(headers, 'sec-fetch-mode') == 'navigate' &&
      _singleFetchMetadataValue(headers, 'sec-fetch-dest') == 'document' &&
      _singleFetchMetadataValue(headers, 'sec-fetch-user') == '?1';
}

String? _singleFetchMetadataValue(HttpHeaders headers, String name) {
  final values = headers[name];
  if (values == null || values.length != 1) return null;
  final value = values.single.trim().toLowerCase();
  return value.isEmpty ? null : value;
}

double? _finiteDouble(Object? value) {
  if (value is! num) return null;
  final parsed = value.toDouble();
  return parsed.isFinite ? parsed : null;
}

int? _exactInteger(Object? value) {
  final parsed = _finiteDouble(value);
  if (parsed == null || parsed.truncateToDouble() != parsed) return null;
  return parsed.toInt();
}

bool _containsControlCharacters(String value) => value.runes.any(
      (rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f),
    );

bool _matchesLocalLeaseTarget(
  ProviderQuota quota,
  List<_LocalLeaseTarget> targets,
) {
  final provider = normalizeLeaseProvider(quota.provider);
  final account = normalizeLeaseAccount(quota.account);
  return targets.any(
    (target) =>
        target.provider == provider &&
        (target.account == null || target.account == account),
  );
}

bool _routeCandidateMatchesLease(RouteCandidate candidate, RouteLease lease) =>
    normalizeLeaseProvider(candidate.provider) == lease.provider &&
    normalizeLeaseAccount(candidate.account) == lease.account;
