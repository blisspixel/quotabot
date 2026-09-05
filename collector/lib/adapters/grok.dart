import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../auth/provider_disconnect.dart';
import '../auth/tokens.dart';
import '../auth/xai_auth.dart';
import '../credential_pool_store.dart';
import '../http_client.dart';
import '../models.dart';
import '../provider_ids.dart';
import '../provider_read_gate.dart';
import '../util.dart';

typedef GrokUsageFetcher = Future<QuotaWindow?> Function(
    String token, int asOf);
typedef GrokTokenResolver = Future<String?> Function(
  String account,
  bool allowDefaultGrant,
);

/// The modern first-party billing envelope, with included quota only.
QuotaWindow? grokBillingWindowFromJson(Map<String, dynamic> response) {
  final config = response['config'];
  return config is Map ? GrokAdapter._includedWindow(config) : null;
}

/// Reads the first-party Grok CLI's included billing metadata. Host credentials
/// are immutable inputs. Independent quotabot grants must prove their principal
/// with the same token before they can supply another billing credential.
class GrokAdapter {
  static const id = grokProviderId;
  static const name = grokProviderName;
  static final _billingUri =
      Uri.parse('https://cli-chat-proxy.grok.com/v1/billing?format=credits');
  static final _userUri =
      Uri.parse('https://cli-chat-proxy.grok.com/v1/user?include=subscription');
  static const _maxAuthBytes = 256 * 1024;
  static const _maxResponseBytes = 128 * 1024;
  final File? _authFile;
  final GrokUsageFetcher? _usageFetcher;
  final GrokTokenResolver? _tokenResolver;
  final bool Function()? _disconnectReader;
  final http.Client? _http;
  final ProviderReadGate _readGate;
  final CredentialPoolStore _poolStore;
  final Duration requestTimeout;
  final Duration grantResolutionDeadline;

  GrokAdapter({
    File? authFile,
    GrokUsageFetcher? usageFetcher,
    GrokTokenResolver? tokenResolver,
    bool Function()? disconnectReader,
    http.Client? client,
    ProviderReadGate? readGate,
    CredentialPoolStore? poolStore,
    this.requestTimeout = const Duration(seconds: 8),
    this.grantResolutionDeadline = const Duration(seconds: 5),
  })  : assert(requestTimeout.inMicroseconds > 0),
        assert(grantResolutionDeadline.inMicroseconds > 0),
        _authFile = authFile,
        _usageFetcher = usageFetcher,
        _tokenResolver = tokenResolver,
        _disconnectReader = disconnectReader,
        _http = client,
        _readGate = readGate ?? ProviderReadGate(),
        _poolStore = poolStore ?? CredentialPoolStore(id);

  static File defaultAuthFile() => File('${home()}/.grok/auth.json');
  static Set<String> get currentAccounts => GrokAdapter().accountIndex;

  /// Current credential discovery only. Stored associations recover last-known
  /// cache keys; they never establish the identity of a new usage response.
  Set<String> get accountIndex {
    if (_disconnected) return const {};
    final host = _readHost(_authFile ?? defaultAuthFile());
    return {
      if (host.credential case final credential?) credential.principal.pool,
      for (final grant in _ownedGrants())
        _poolStore.lookup(grant.identity)?.pool ?? grant.identity,
    };
  }

  bool get _disconnected =>
      (_disconnectReader ?? () => ProviderDisconnectStore.isDisconnected(id))();

  Future<ProviderQuota> collect() async => (await collectAccounts()).first;

  Future<List<ProviderQuota>> collectAccounts() async {
    final asOf = nowEpoch();
    if (_disconnected) {
      return [_error(providerDisconnectedMessage(id), asOf)];
    }
    final host = _readHost(_authFile ?? defaultAuthFile());
    final grants = _ownedGrants();
    if (host.credential == null && grants.isEmpty) {
      return [
        _error(host.error ?? 'no Grok account - run: quotabot login grok', asOf)
      ];
    }

    final reads = <String, Future<ProviderQuota>>{};
    final attemptedTokens = <String>{};
    Future<ProviderQuota> readOnce(_Credential credential) async {
      final pool = credential.principal.pool;
      while (true) {
        final previous = reads[pool];
        if (previous == null) break;
        final result = await previous;
        if (!identical(reads[pool], previous)) continue;
        // Only an explicit authentication rejection permits another currently
        // authorized credential for this proven pool. Never evade a cooldown.
        if (result.httpStatus != 401 ||
            attemptedTokens.contains(credential.tokenIdentity)) {
          return result;
        }
        break;
      }
      attemptedTokens.add(credential.tokenIdentity);
      final result = _readBilling(credential, asOf);
      reads[pool] = result;
      return result;
    }

    // Start usable host reads before resolving optional quotabot grants. An
    // absent, failed or contended grant cannot discard the host's result.
    final pending = <Future<ProviderQuota>>[
      if (host.credential case final credential?)
        credential.needsUserDiscovery &&
                (credential.expiresAt == null || credential.expiresAt! > asOf)
            ? _discoverAndRead(credential.token, credential.tokenIdentity,
                credential.principal.pool, asOf, readOnce,
                expectedPool: credential.principal.pool)
            : readOnce(credential),
      for (final grant in grants) _readOwned(grant, asOf, readOnce),
    ];
    final results = await Future.wait(pending);
    final byAccount = <String, ProviderQuota>{};
    for (final result in results) {
      final previous = byAccount[result.account];
      if (previous == null || result.error == null) {
        byAccount[result.account] = result;
      }
    }
    return byAccount.values.toList(growable: false);
  }

  Future<ProviderQuota> _readOwned(
    _OwnedGrant grant,
    int asOf,
    Future<ProviderQuota> Function(_Credential) readOnce,
  ) async {
    final lastAccount =
        _poolStore.lookup(grant.identity)?.pool ?? grant.identity;
    try {
      final String? token;
      if (_tokenResolver case final resolver?) {
        token = await resolver(grant.owner, grant.isDefault)
            .timeout(grantResolutionDeadline);
      } else {
        final auth = XaiAuth(
          client: _http,
          requestTimeout: grantResolutionDeadline,
          refreshAcquisitionTimeout: const Duration(milliseconds: 100),
        );
        token = await auth.freshAccessToken(
          account: grant.isDefault ? null : grant.owner,
          requiredDefaultOwner: grant.isDefault ? grant.owner : null,
        );
      }
      if (!_usableToken(token)) {
        return _error('Grok grant unavailable - run: quotabot login grok', asOf,
            account: lastAccount);
      }
      // Reload after refresh so a rotation is associated with its current
      // generation. A concurrent login replacement cannot inherit the old pool.
      final current = TokenStore.loadRecord(id,
          account: grant.isDefault ? null : grant.owner);
      if (current == null ||
          current.owner != grant.owner ||
          (_tokenResolver == null && current.tokens.accessToken != token)) {
        return _error(
            'Grok grant changed - refresh to read the current account', asOf,
            account: lastAccount);
      }
      return await _discoverAndRead(
          token!, _grantIdentity(current.tokens), lastAccount, asOf, readOnce);
    } catch (error) {
      return _readError(error, asOf, lastAccount);
    }
  }

  Future<ProviderQuota> _discoverAndRead(
    String token,
    String identity,
    String lastAccount,
    int asOf,
    Future<ProviderQuota> Function(_Credential) readOnce, {
    String? expectedPool,
  }) async {
    final result = await _readGate.run<_ProfileRead>(
      provider: id,
      credentialIdentity: identity,
      purpose: ProviderReadPurpose.profile,
      attempt: (operation) async {
        try {
          final observed = DateTime.now().microsecondsSinceEpoch;
          final response = await operation.track(_getBounded(_userUri, token));
          if (response.statusCode != 200) {
            return _ProfileRead.failure(
                _httpError(response, asOf, lastAccount));
          }
          final raw = jsonDecode(response.body);
          final principal =
              raw is Map ? _principal(raw, camelCase: true) : null;
          if (principal == null) {
            return _ProfileRead.failure(_error(
                'Grok account identity unavailable', asOf,
                account: lastAccount));
          }
          if (expectedPool != null && principal.pool != expectedPool) {
            return _ProfileRead.failure(_error(
                'Grok account identity changed - sign in again with the current Grok CLI',
                asOf,
                account: lastAccount));
          }
          _poolStore.remember(identity, principal.pool,
              observedAtMicros: observed);
          final plan = raw['subscriptionTier'];
          return _ProfileRead.success(_Credential(token, principal,
              plan: plan is String &&
                      RegExp(r'^[A-Za-z0-9 _-]{1,64}$').hasMatch(plan)
                  ? plan
                  : null));
        } catch (error) {
          return _ProfileRead.failure(_readError(error, asOf, lastAccount));
        }
      },
      classify: (result) => result.error == null
          ? const ProviderReadDisposition.completed()
          : _disposition(result.error!),
      deferred: (deferral) =>
          _ProfileRead.failure(_deferred(deferral, asOf, lastAccount)),
    );
    return result.credential == null
        ? result.error!
        : readOnce(result.credential!);
  }

  Future<ProviderQuota> _readBilling(_Credential credential, int asOf) {
    final account = credential.principal.pool;
    if (credential.expiresAt != null && credential.expiresAt! <= asOf) {
      return Future.value(_error(
          'Grok login expired - open Grok or run: quotabot login grok', asOf,
          account: account, status: 401));
    }
    return _readGate.run<ProviderQuota>(
      provider: id,
      // Exact typed first-party principal evidence independently proves the
      // billing pool, including when two current grants represent that pool.
      credentialIdentity: account,
      purpose: ProviderReadPurpose.usage,
      attempt: (operation) async {
        try {
          final QuotaWindow? window;
          if (_usageFetcher case final fetch?) {
            window = await operation.track(fetch(credential.token, asOf));
          } else {
            final response = await operation.track(_getBounded(
                _billingUri, credential.token,
                userId: credential.principal.userId));
            if (response.statusCode != 200) {
              return _httpError(response, asOf, account);
            }
            final body = jsonDecode(response.body);
            window = body is Map<String, dynamic>
                ? grokBillingWindowFromJson(body)
                : null;
          }
          if (window == null) {
            return _error('Grok included quota unavailable', asOf,
                account: account);
          }
          return ProviderQuota(
            provider: id,
            displayName: name,
            account: account,
            plan: credential.plan,
            planEvidenceSource: credential.plan == null
                ? null
                : ProviderPlanEvidenceSource.providerMetadata,
            planEvidenceAsOf: credential.plan == null ? null : asOf,
            asOf: asOf,
            windows: [window],
            details: [
              credential.principal.team ? 'Team account' : 'Personal account',
              'Prepaid and on-demand balances do not increase included quota.',
            ],
          );
        } catch (error) {
          return _readError(error, asOf, account);
        }
      },
      classify: _disposition,
      deferred: (deferral) => _deferred(deferral, asOf, account),
    );
  }

  Future<http.Response> _getBounded(Uri uri, String token,
      {String? userId}) async {
    final abort = Completer<void>();
    var expired = false;
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    final timer = Timer(requestTimeout, () {
      expired = true;
      cancel();
    });
    try {
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers.addAll({
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
              'X-XAI-Token-Auth': 'xai-grok-cli',
              if (userId != null) 'x-userid': userId,
            });
      final response = await (_http ?? sharedHttpClient).send(request);
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > _maxResponseBytes) {
        cancel();
        await response.stream.listen(null).cancel();
        if (expired) throw TimeoutException('Grok metadata deadline');
        if (response.statusCode == 200) {
          throw const FormatException('Grok response exceeds size limit');
        }
        return http.Response('', response.statusCode,
            headers: response.headers);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > _maxResponseBytes) {
          cancel();
          throw const FormatException('Grok response exceeds size limit');
        }
        bytes.add(chunk);
      }
      if (expired) throw TimeoutException('Grok metadata deadline');
      return http.Response.bytes(bytes.takeBytes(), response.statusCode,
          headers: response.headers);
    } on http.RequestAbortedException {
      if (expired) throw TimeoutException('Grok metadata deadline');
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  static _HostRead _readHost(File authFile) {
    try {
      if (!authFile.existsSync()) return const _HostRead();
      final handle = authFile.openSync();
      late final List<int> bytes;
      try {
        bytes = handle.readSync(_maxAuthBytes + 1);
      } finally {
        handle.closeSync();
      }
      if (bytes.length > _maxAuthBytes) {
        return const _HostRead(error: 'Grok auth metadata exceeds size limit');
      }
      final auth = jsonDecode(utf8.decode(bytes));
      if (auth is! Map) {
        return const _HostRead(error: 'invalid Grok auth metadata');
      }
      final raw = auth[XaiAuth.hostScope];
      if (raw is! Map) {
        return _HostRead(
            error: auth.containsKey('https://accounts.x.ai/sign-in')
                ? 'Legacy Grok login unsupported - sign in again with the current Grok CLI'
                : 'no supported first-party Grok account');
      }
      if ((raw['auth_mode'] != 'oidc' && raw['auth_mode'] != 'external') ||
          raw['oidc_issuer'] != XaiAuth.issuer ||
          (raw['oidc_client_id'] != null &&
              raw['oidc_client_id'] != XaiAuth.publicClientId)) {
        return const _HostRead(
            error:
                'Grok login unsupported - use the current first-party Grok CLI');
      }
      final principal = _principal(raw, camelCase: false);
      final token = raw['key'];
      if (principal == null || !_usableToken(token)) {
        return const _HostRead(
            error: 'Grok account identity or credential unavailable');
      }
      final expires = raw['expires_at'];
      final created = raw['create_time'];
      final createdAt = _timestamp(created);
      if (expires != null && _timestamp(expires) == null) {
        return const _HostRead(error: 'invalid Grok login expiry');
      }
      return _HostRead(
          credential: _Credential(
        token as String,
        principal,
        expiresAt: expires != null
            ? _timestamp(expires)
            : createdAt == null
                ? null
                : createdAt + 30 * 86400,
        // The official team login initially stores its team ID in user_id.
        // Resolve that placeholder with this same token before sending x-userid.
        needsUserDiscovery: principal.team && principal.userId == principal.id,
      ));
    } catch (_) {
      return const _HostRead(error: 'unable to read Grok auth metadata');
    }
  }

  static List<_OwnedGrant> _ownedGrants() {
    final result = <_OwnedGrant>[];
    final owners = <String>{};
    try {
      for (final owner in TokenStore.accounts(id)) {
        final record = TokenStore.loadRecord(id, account: owner);
        if (record == null ||
            record.owner != owner ||
            !_hasGrant(record.tokens)) {
          continue;
        }
        owners.add(owner);
        result.add(_OwnedGrant(owner, false, _grantIdentity(record.tokens)));
      }
      final fallback = TokenStore.loadRecord(id);
      if (fallback != null &&
          fallback.owner != null &&
          !owners.contains(fallback.owner) &&
          _hasGrant(fallback.tokens)) {
        result.add(_OwnedGrant(
            fallback.owner!, true, _grantIdentity(fallback.tokens)));
      }
    } catch (_) {
      // An optional grant-store failure cannot discard a usable host login.
    }
    return result;
  }

  static bool _hasGrant(Tokens tokens) =>
      _usableToken(tokens.accessToken) || _usableToken(tokens.refreshToken);
  static String _grantIdentity(Tokens tokens) => opaqueCredentialIdentity(id,
      'owned-grant:${_usableToken(tokens.refreshToken) ? tokens.refreshToken : tokens.accessToken}');

  static bool _usableToken(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 64 * 1024 &&
      value.codeUnits.every((c) => c >= 0x21 && c <= 0x7e);

  static String? _identifier(Object? value) =>
      value is String && RegExp(r'^[A-Za-z0-9._:-]{1,256}$').hasMatch(value)
          ? value
          : null;

  static _Principal? _principal(Map<dynamic, dynamic> raw,
      {required bool camelCase}) {
    final user = _identifier(raw[camelCase ? 'userId' : 'user_id']);
    final type = raw[camelCase ? 'principalType' : 'principal_type'];
    final principal = raw[camelCase ? 'principalId' : 'principal_id'];
    final team = raw[camelCase ? 'teamId' : 'team_id'];
    if (user == null) return null;
    if (type == null && principal == null && team == null) {
      return _Principal(user, user, false);
    }
    if (type == 'Team' && _identifier(principal) != null && principal == team) {
      return _Principal(user, principal as String, true);
    }
    return null;
  }

  static QuotaWindow? _includedWindow(Map<dynamic, dynamic> config) {
    if (config.containsKey('creditUsagePercent') ||
        config.containsKey('currentPeriod')) {
      final percent = config['creditUsagePercent'];
      final period = config['currentPeriod'];
      if (percent is! num ||
          !percent.isFinite ||
          percent < 0 ||
          percent > 100 ||
          period is! Map) {
        return null;
      }
      final label = switch (period['type']) {
        'USAGE_PERIOD_TYPE_WEEKLY' => 'weekly',
        'USAGE_PERIOD_TYPE_MONTHLY' => 'monthly',
        _ => null,
      };
      final end = _timestamp(period['end']);
      final start = _timestamp(period['start']);
      if (label == null ||
          end == null ||
          (period['start'] != null && (start == null || start >= end))) {
        return null;
      }
      return QuotaWindow(
          label: label, usedPercent: percent.toDouble(), resetsAt: end);
    }
    // The pinned billing client retains these deprecated INCLUDED cents. A
    // present-invalid modern field never falls through to the older evidence.
    final limit = _cents(config['monthlyLimit']);
    final used = _cents(config['used']);
    final end = _timestamp(config['billingPeriodEnd']);
    final start = _timestamp(config['billingPeriodStart']);
    if (limit == null ||
        limit <= 0 ||
        used == null ||
        used > limit ||
        end == null ||
        (config['billingPeriodStart'] != null &&
            (start == null || start >= end))) {
      return null;
    }
    return QuotaWindow(
        label: 'monthly',
        usedPercent: 100 * used / limit,
        used: used,
        limit: limit,
        resetsAt: end);
  }

  static int? _cents(Object? raw) {
    if (raw is! Map) return null;
    final value = raw.containsKey('val') ? raw['val'] : 0;
    return value is int && value >= 0 && value <= 9007199254740991
        ? value
        : null;
  }

  static int? _timestamp(Object? raw) {
    if (raw is! String || raw.length > 64) return null;
    final match = RegExp(
            r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$')
        .firstMatch(raw);
    if (match == null) return null;
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final hour = int.parse(match[4]!);
    final minute = int.parse(match[5]!);
    final second = int.parse(match[6]!);
    final date = DateTime.utc(year, month, day);
    if (date.year != year ||
        date.month != month ||
        date.day != day ||
        hour > 23 ||
        minute > 59 ||
        second > 59) {
      return null;
    }
    final zone = match[7]!;
    if (zone != 'Z' &&
        (int.parse(zone.substring(1, 3)) > 23 ||
            int.parse(zone.substring(4)) > 59)) {
      return null;
    }
    final parsed = DateTime.tryParse(raw);
    return parsed == null ? null : parsed.millisecondsSinceEpoch ~/ 1000;
  }

  static ProviderQuota _error(String note, int asOf,
          {String account = 'default',
          String? health,
          int? status,
          int? retryAfter}) =>
      ProviderQuota.error(id, name, note, asOf,
          account: account,
          pipeHealth: health,
          httpStatus: status,
          retryAfterSeconds: retryAfter);

  static ProviderQuota _httpError(
          http.Response response, int asOf, String account) =>
      _error(
          response.statusCode == 401
              ? 'Grok login rejected - open Grok or run: quotabot login grok'
              : 'Grok quota read HTTP ${response.statusCode}',
          asOf,
          account: account,
          status: response.statusCode,
          health: providerPipeHealthForHttpStatus(response.statusCode),
          retryAfter:
              retryAfterSeconds(response.headers['retry-after'], now: asOf));

  static ProviderQuota _readError(
          Object error, int asOf, String account) =>
      _error(
          error is TimeoutException
              ? 'Grok metadata read timed out'
              : 'unable to read Grok metadata',
          asOf,
          account: account,
          health: providerPipeHealthForReadError(error));

  static ProviderReadDisposition _disposition(ProviderQuota quota) {
    if (quota.error == null || quota.httpStatus == 401) {
      return const ProviderReadDisposition.completed();
    }
    if (quota.httpStatus case final status?) {
      return ProviderReadDisposition.httpFailure(status,
          retryAfterSeconds: quota.retryAfterSeconds);
    }
    return ProviderReadDisposition.failed(
        quota.pipeHealth == providerPipeHealthThrottled
            ? ProviderReadFailure.timedOut
            : ProviderReadFailure.unavailable);
  }

  static ProviderQuota _deferred(
          ProviderReadDeferral deferral, int asOf, String account) =>
      _error(
          switch (deferral.reason) {
            ProviderReadDeferralReason.cooldown =>
              'Grok metadata read deferred until retry deadline',
            ProviderReadDeferralReason.busy =>
              'Grok metadata read already in progress',
            _ => 'Grok metadata temporarily unavailable',
          },
          asOf,
          account: account,
          status: deferral.httpStatus,
          retryAfter: deferral.retryAfterSeconds,
          health: deferral.failure == ProviderReadFailure.rateLimited ||
                  deferral.failure == ProviderReadFailure.timedOut
              ? providerPipeHealthThrottled
              : providerPipeHealthDegraded);
}

class _Principal {
  const _Principal(this.userId, this.id, this.team);
  final String userId;
  final String id;
  final bool team;
  String get pool => opaqueCredentialIdentity(
      GrokAdapter.id, 'grok-principal-v1:${team ? 'Team' : 'User'}:$id');
}

class _Credential {
  const _Credential(this.token, this.principal,
      {this.plan, this.expiresAt, this.needsUserDiscovery = false});
  final String token;
  final _Principal principal;
  final String? plan;
  final int? expiresAt;
  final bool needsUserDiscovery;
  String get tokenIdentity => opaqueCredentialIdentity(GrokAdapter.id, token);
}

class _OwnedGrant {
  const _OwnedGrant(this.owner, this.isDefault, this.identity);
  final String owner;
  final bool isDefault;
  final String identity;
}

class _HostRead {
  const _HostRead({this.credential, this.error});
  final _Credential? credential;
  final String? error;
}

class _ProfileRead {
  const _ProfileRead.success(this.credential) : error = null;
  const _ProfileRead.failure(this.error) : credential = null;
  final _Credential? credential;
  final ProviderQuota? error;
}
