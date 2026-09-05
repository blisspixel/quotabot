import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/cache.dart';
import 'package:quotabot_collector/models.dart';

import '../../bin/collect.dart' as cli;

/// A real CLI invocation whose only metadata transport is synthetic. All local
/// paths are provided by the parent test's isolated process environment.
Future<void> main(List<String> args) async {
  final cached = args.first == 'cached-unresolved';
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (cached) {
    saveSnapshot(ProviderQuota.fromJson({
      'provider': 'codex',
      'display_name': 'Codex',
      'account': opaqueCredentialIdentity('codex', 'account-id:cli-projection'),
      'as_of': now,
      'request_admission': 'future-admission',
      'windows': [
        {'label': 'weekly', 'used_percent': 50, 'resets_at': now + 86400}
      ],
    }));
  }
  var requests = 0;
  await http.runWithClient(() async {
    await cli.main(args.skip(1).toList());
  },
      () => MockClient((request) async {
            requests++;
            if (request.method != 'GET' ||
                request.url.toString() !=
                    'https://chatgpt.com/backend-api/wham/usage') {
              throw StateError('unexpected synthetic metadata request');
            }
            if (cached) return http.Response('{}', 503);
            return http.Response(
                jsonEncode({
                  'rate_limit': {
                    'allowed': false,
                    'limit_reached': true,
                    'primary_window': {
                      'used_percent': 50,
                      'reset_at': now + 86400,
                      'limit_window_seconds': 604800
                    },
                    'secondary_window': null,
                  }
                }),
                200);
          }));
  if (requests != 1) throw StateError('expected one synthetic quota read');
}
