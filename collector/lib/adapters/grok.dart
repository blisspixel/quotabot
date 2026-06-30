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
/// usage percent for the current billing cycle and the cycle reset time. This
/// is a billing metadata call, not a model call, so it costs no tokens.
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
      final out = <ProviderQuota>[];
      for (var i = 0; i < accounts.length; i++) {
        out.add(
          await _collectAccount(
            accounts[i],
            asOf,
            allowDefaultGrant: i == 0,
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
  }

  Future<String?> _resolveToken(String account, bool allowDefaultGrant) async {
    if (_tokenResolver != null) {
      return _tokenResolver(account, allowDefaultGrant);
    }
    final xai = XaiAuth();
    return await xai.freshAccessToken(account: account) ??
        (allowDefaultGrant ? await xai.freshAccessToken() : null);
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
