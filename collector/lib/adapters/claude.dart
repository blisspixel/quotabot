import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models.dart';
import '../parsing.dart';
import '../provider_ids.dart';
import '../util.dart';

/// Reads Claude (Anthropic) usage live from the OAuth usage endpoint, reusing
/// the access token Claude Code already stores in ~/.claude/.credentials.json.
/// This is the same data shown by the in-CLI `/usage` command.
class ClaudeAdapter {
  static const id = claudeProviderId;
  static const name = claudeProviderName;
  static const _endpoint = 'https://api.anthropic.com/api/oauth/usage';

  Future<ProviderQuota> collect() async {
    final asOf = nowEpoch();
    try {
      final credFile = File('${home()}/.claude/.credentials.json');
      if (!credFile.existsSync()) {
        return ProviderQuota.error(
          id,
          name,
          'no ~/.claude/.credentials.json',
          asOf,
        );
      }
      final oauth = (jsonDecode(credFile.readAsStringSync())
          as Map)['claudeAiOauth'] as Map?;
      final token = oauth?['accessToken'] as String?;
      if (token == null) {
        return ProviderQuota.error(id, name, 'no oauth access token', asOf);
      }
      final plan = oauth?['subscriptionType']?.toString();

      final resp = await http.get(
        Uri.parse(_endpoint),
        headers: {
          'Authorization': 'Bearer $token',
          'anthropic-beta': 'oauth-2025-04-20',
          'anthropic-version': '2023-06-01',
        },
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 401) {
        return ProviderQuota.error(
          id,
          name,
          'token expired (re-run claude)',
          asOf,
        );
      }
      if (resp.statusCode != 200) {
        return ProviderQuota.error(id, name, 'HTTP ${resp.statusCode}', asOf);
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return ProviderQuota(
        provider: id,
        displayName: name,
        account: plan ?? 'default',
        plan: plan,
        asOf: asOf,
        windows: claudeWindows(data),
      );
    } catch (_) {
      return ProviderQuota.error(id, name, 'unable to read Claude usage', asOf);
    }
  }
}
