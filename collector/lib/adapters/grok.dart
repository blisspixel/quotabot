import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../auth/provider_disconnect.dart';
import '../auth/xai_auth.dart';
import '../http_client.dart';
import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';

typedef GrokUsageFetcher = Future<QuotaWindow?> Function(
    String token, int asOf);
typedef GrokTokenResolver = Future<String?> Function(
  String account,
  bool allowDefaultGrant,
);

/// Grok (xAI) adapter.
///
/// Grok Build does not persist usage to disk, but its billing config is
/// available from a gRPC-web endpoint on grok.com using the bearer token the
/// CLI already stores in ~/.grok/auth.json. The response carries the credit
/// usage percent for the shared paid-plan weekly pool and reset time. This is a
/// billing metadata call, not a model call, so it costs no tokens.
class GrokAdapter {
  static const id = grokProviderId;
  static const name = grokProviderName;
  static const _endpoint =
      'https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig';
  final File? _authFile;
  final GrokUsageFetcher? _usageFetcher;
  final GrokTokenResolver? _tokenResolver;
  final bool Function()? _disconnectReader;
  final http.Client? _http;

  GrokAdapter({
    File? authFile,
    GrokUsageFetcher? usageFetcher,
    GrokTokenResolver? tokenResolver,
    bool Function()? disconnectReader,
    http.Client? client,
  })  : _authFile = authFile,
        _usageFetcher = usageFetcher,
        _tokenResolver = tokenResolver,
        _disconnectReader = disconnectReader,
        _http = client;

  static File defaultAuthFile() => File('${home()}/.grok/auth.json');

  static Set<String> get currentAccounts {
    try {
      if (ProviderDisconnectStore.isDisconnected(id)) return const {};
      return _readAccounts(defaultAuthFile()).map((a) => a.email).toSet();
    } catch (_) {
      return const {};
    }
  }

  Future<ProviderQuota> collect() async {
    final results = await collectAccounts();
    return results.first;
  }

  Future<List<ProviderQuota>> collectAccounts() async {
    final asOf = nowEpoch();
    try {
      if ((_disconnectReader ??
          () => ProviderDisconnectStore.isDisconnected(id))()) {
        return [
          ProviderQuota.error(
            id,
            name,
            providerDisconnectedMessage(id),
            asOf,
          ),
        ];
      }
      final authFile = _authFile ?? defaultAuthFile();
      if (!authFile.existsSync()) {
        return [ProviderQuota.error(id, name, 'no ~/.grok/auth.json', asOf)];
      }
      final accounts = _readAccounts(authFile);
      if (accounts.isEmpty) {
        return [ProviderQuota.error(id, name, 'no grok account', asOf)];
      }
      // The provider-default grant has no recorded owner, so it may only stand
      // in for the primary account when there is exactly one account to read.
      // With several accounts, lending the default to the first would risk
      // fetching one account's usage under another account's label, since the
      // Grok billing response carries no identity to cross-check.
      final soleAccount = accounts.length == 1;
      final out = <ProviderQuota>[];
      for (var i = 0; i < accounts.length; i++) {
        out.add(
          await _collectAccount(
            accounts[i],
            asOf,
            allowDefaultGrant: i == 0 && soleAccount,
          ),
        );
      }
      return out;
    } catch (_) {
      return [ProviderQuota.error(id, name, 'unable to read Grok usage', asOf)];
    }
  }

  Future<ProviderQuota> _collectAccount(
    _GrokAccount account,
    int asOf, {
    required bool allowDefaultGrant,
  }) async {
    ProviderQuota offline(String note, {int? httpStatus}) => ProviderQuota(
          provider: id,
          displayName: name,
          account: account.email,
          plan: 'SuperGrok',
          asOf: asOf,
          ok: true,
          error: note,
          windows: const [],
          httpStatus: httpStatus,
        );

    ProviderQuota failed({
      required String message,
      String? pipeHealth,
      int? httpStatus,
      int? retryAfterSeconds,
    }) =>
        ProviderQuota.error(
          id,
          name,
          message,
          asOf,
          account: account.email,
          plan: 'SuperGrok',
          pipeHealth: pipeHealth,
          httpStatus: httpStatus,
          retryAfterSeconds: retryAfterSeconds,
        );

    try {
      final token = await _resolveToken(account.email, allowDefaultGrant) ??
          account.cliToken;
      if (token == null) return offline('no token - run: quotabot login grok');

      final injected = _usageFetcher;
      if (injected != null) {
        final window = await injected(token, asOf);
        if (window == null) {
          return offline('token expired (open Grok to refresh) - account only');
        }
        return ProviderQuota(
          provider: id,
          displayName: name,
          account: account.email,
          plan: 'SuperGrok',
          asOf: asOf,
          windows: [window],
        );
      }

      final snapshot = await _fetchUsage(token, asOf);
      if (snapshot.window != null) {
        return ProviderQuota(
          provider: id,
          displayName: name,
          account: account.email,
          plan: 'SuperGrok',
          asOf: asOf,
          windows: [snapshot.window!],
          details: snapshot.details,
        );
      }
      if (snapshot.unauthorized) {
        return offline(
          snapshot.error ??
              'token expired (open Grok to refresh) - account only',
          httpStatus: snapshot.httpStatus,
        );
      }
      return failed(
        message: snapshot.error ?? 'unable to read Grok usage',
        pipeHealth: snapshot.pipeHealth,
        httpStatus: snapshot.httpStatus,
        retryAfterSeconds: snapshot.retryAfterSeconds,
      );
    } catch (e) {
      // Isolate this account: a token-refresh or network throw here must not
      // escape to collectAccounts' single catch, which would discard the other
      // accounts' results already gathered in the fan-out.
      final health = providerPipeHealthForReadError(e);
      return failed(
        message: health == providerPipeHealthThrottled
            ? 'Grok usage read timed out'
            : 'unable to read this account (network or token error)',
        pipeHealth: health,
      );
    }
  }

  Future<String?> _resolveToken(String account, bool allowDefaultGrant) async {
    if (_tokenResolver != null) {
      return _tokenResolver(account, allowDefaultGrant);
    }
    final xai = XaiAuth();
    final own = await xai.freshAccessToken(account: account);
    if (own != null) return own;
    if (!allowDefaultGrant) return null;
    // The Grok billing response carries no identity, so the default grant may
    // only stand in for this account when it is unclaimed (a legacy grant, and
    // allowDefaultGrant already limits that to the sole account) or is stamped
    // for this account. Lending a default owned by a different account would
    // show that account's usage under this one.
    return await xai.freshAccessToken(requiredDefaultOwner: account);
  }

  static List<_GrokAccount> _readAccounts(File authFile) {
    final auth = jsonDecode(authFile.readAsStringSync()) as Map;
    final out = <_GrokAccount>[];
    final seen = <String>{};
    for (final raw in auth.values) {
      if (raw is! Map) continue;
      final email = raw['email']?.toString();
      final account = (email == null || email.isEmpty) ? 'default' : email;
      if (!seen.add(account)) continue;
      out.add(_GrokAccount(account, raw['key']?.toString()));
    }
    return out;
  }

  /// Calls the gRPC-web billing endpoint and parses the credit usage window.
  Future<_GrokUsageSnapshot> _fetchUsage(
    String token,
    int asOf,
  ) async {
    // gRPC-web data frame: flag(0) + length(0) = empty request message.
    final body = Uint8List.fromList([0, 0, 0, 0, 0]);
    final post = _http?.post ?? sharedHttpClient.post;
    final resp = await post(
      Uri.parse(_endpoint),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/grpc-web+proto',
        'x-grpc-web': '1',
        'User-Agent': 'grok-cli',
      },
      body: body,
    ).timeout(const Duration(seconds: 12));
    final retryAfter =
        retryAfterSeconds(resp.headers['retry-after'], now: asOf);
    if (resp.statusCode == 401) {
      return _GrokUsageSnapshot.fail(
        error: 'token expired (open Grok to refresh) - account only',
        httpStatus: resp.statusCode,
        unauthorized: true,
      );
    }
    if (resp.statusCode != 200) {
      return _GrokUsageSnapshot.fail(
        error: 'HTTP ${resp.statusCode}',
        pipeHealth: providerPipeHealthForHttpStatus(resp.statusCode),
        httpStatus: resp.statusCode,
        retryAfterSeconds: retryAfter,
      );
    }
    final headerStatus = int.tryParse(
      (resp.headers['grpc-status'] ?? '').trim(),
    );
    if (headerStatus != null && headerStatus != 0) {
      return _grokGrpcStatusFailure(
        headerStatus,
        httpStatus: resp.statusCode,
        retryAfterSeconds: retryAfter,
      );
    }
    final trailerStatus = grpcWebTrailerStatus(resp.bodyBytes);
    if (trailerStatus != null && trailerStatus != 0) {
      return _grokGrpcStatusFailure(
        trailerStatus,
        httpStatus: resp.statusCode,
        retryAfterSeconds: retryAfter,
      );
    }
    final message = grpcMessage(resp.bodyBytes);
    final window = grokWindow(message, asOf);
    if (window == null) {
      return const _GrokUsageSnapshot.fail(
        error: 'invalid Grok usage response',
      );
    }
    return _GrokUsageSnapshot.ok(window, grokCategoryDetails(message));
  }
}

class _GrokUsageSnapshot {
  final QuotaWindow? window;
  final List<String> details;
  final String? error;
  final String? pipeHealth;
  final int? httpStatus;
  final int? retryAfterSeconds;
  final bool unauthorized;

  const _GrokUsageSnapshot.ok(this.window, this.details)
      : error = null,
        pipeHealth = null,
        httpStatus = null,
        retryAfterSeconds = null,
        unauthorized = false;

  const _GrokUsageSnapshot.fail({
    required this.error,
    this.pipeHealth,
    this.httpStatus,
    this.retryAfterSeconds,
    this.unauthorized = false,
  })  : window = null,
        details = const [];
}

_GrokUsageSnapshot _grokGrpcStatusFailure(
  int status, {
  int? httpStatus,
  int? retryAfterSeconds,
}) {
  if (status == 16) {
    return _GrokUsageSnapshot.fail(
      error: 'token expired (open Grok to refresh) - account only',
      httpStatus: httpStatus,
      unauthorized: true,
    );
  }
  final pipeHealth = switch (status) {
    4 || 8 => providerPipeHealthThrottled,
    2 || 13 || 14 => providerPipeHealthDegraded,
    _ => null,
  };
  return _GrokUsageSnapshot.fail(
    error: 'gRPC status $status',
    pipeHealth: pipeHealth,
    httpStatus: httpStatus,
    retryAfterSeconds: retryAfterSeconds,
  );
}

class _GrokAccount {
  final String email;
  final String? cliToken;
  const _GrokAccount(this.email, this.cliToken);
}
