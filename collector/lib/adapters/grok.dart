import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../auth/xai_auth.dart';
import '../models.dart';
import '../parsing.dart';
import '../util.dart';

/// Grok (xAI) adapter.
///
/// Grok Build does not persist usage to disk, but its billing config is
/// available from a gRPC-web endpoint on grok.com using the bearer token the
/// CLI already stores in ~/.grok/auth.json. The response carries the credit
/// usage percent for the current billing cycle and the cycle reset time. This
/// is a billing metadata call, not a model call, so it costs no tokens.
class GrokAdapter {
  static const id = 'grok';
  static const name = 'Grok';
  static const _endpoint =
      'https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig';

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final authFile = File('${home()}/.grok/auth.json');
      if (!authFile.existsSync()) {
        return ProviderQuota.error(id, name, 'no ~/.grok/auth.json', asOf);
      }
      final auth = jsonDecode(authFile.readAsStringSync()) as Map;
      if (auth.isEmpty) {
        return ProviderQuota.error(id, name, 'no grok account', asOf);
      }
      final acct = auth.values.first as Map;
      final email = acct['email']?.toString() ?? 'default';

      ProviderQuota offline(String note) => ProviderQuota(
            provider: id,
            displayName: name,
            account: email,
            plan: 'SuperGrok',
            asOf: asOf,
            ok: true,
            error: note,
            windows: const [],
          );

      // Prefer quotabot's own refreshable grant; fall back to the token the CLI
      // currently holds (live only while the CLI keeps it fresh).
      final xai = XaiAuth();
      final token = await xai.freshAccessToken(account: email) ??
          await xai.freshAccessToken() ??
          acct['key']?.toString();
      if (token == null) return offline('no token - run: quotabot login grok');

      final window = await _fetchUsage(token, asOf);
      if (window == null) {
        return offline('token expired (open Grok to refresh) - account only');
      }

      return ProviderQuota(
        provider: id,
        displayName: name,
        account: email,
        plan: 'SuperGrok',
        asOf: asOf,
        windows: [window],
      );
    } catch (_) {
      return ProviderQuota.error(id, name, 'unable to read Grok usage', asOf);
    }
  }

  /// Calls the gRPC-web billing endpoint and parses the credit usage window.
  Future<QuotaWindow?> _fetchUsage(String token, int asOf) async {
    // gRPC-web data frame: flag(0) + length(0) = empty request message.
    final body = Uint8List.fromList([0, 0, 0, 0, 0]);
    final resp = await http
        .post(
          Uri.parse(_endpoint),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/grpc-web+proto',
            'x-grpc-web': '1',
            'User-Agent': 'grok-cli',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    if (resp.headers['grpc-status'] != null &&
        resp.headers['grpc-status'] != '0') {
      return null;
    }
    return grokWindow(grpcMessage(resp.bodyBytes), asOf);
  }
}
