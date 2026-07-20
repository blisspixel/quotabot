import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../auth/xai_auth.dart';
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
  final http.Client? _http;

  GrokAdapter({
    File? authFile,
    GrokUsageFetcher? usageFetcher,
    GrokTokenResolver? tokenResolver,
    http.Client? client,
  })  : _authFile = authFile,
        _usageFetcher = usageFetcher,
        _tokenResolver = tokenResolver,
        _http = client;

  static File defaultAuthFile() => File('${home()}/.grok/auth.json');

  static Set<String> get currentAccounts {
    try {
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
    ProviderQuota offline(String note) => ProviderQuota(
          provider: id,
          displayName: name,
          account: account.email,
          plan: 'SuperGrok',
          asOf: asOf,
          ok: true,
          error: note,
          windows: const [],
        );

    try {
      final token = await _resolveToken(account.email, allowDefaultGrant) ??
          account.cliToken;
      if (token == null) return offline('no token - run: quotabot login grok');

      final window = await (_usageFetcher ?? _fetchUsage)(token, asOf);
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
    } catch (_) {
      // Isolate this account: a token-refresh or network throw here must not
      // escape to collectAccounts' single catch, which would discard the other
      // accounts' results already gathered in the fan-out.
      return offline('unable to read this account (network or token error)');
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
  Future<QuotaWindow?> _fetchUsage(String token, int asOf) async {
    // gRPC-web data frame: flag(0) + length(0) = empty request message.
    final body = Uint8List.fromList([0, 0, 0, 0, 0]);
    final post = _http?.post ?? http.post;
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
    if (resp.statusCode != 200) return null;
    if (resp.headers['grpc-status'] != null &&
        resp.headers['grpc-status'] != '0') {
      return null;
    }
    return grokWindow(grpcMessage(resp.bodyBytes), asOf);
  }
}

class _GrokAccount {
  final String email;
  final String? cliToken;
  const _GrokAccount(this.email, this.cliToken);
}
