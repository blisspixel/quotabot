import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/auth/provider_disconnect.dart';

import '../../bin/collect.dart' as cli;

/// Runs the real first-run collector with isolated paths and synthetic metadata.
Future<void> main(List<String> args) async {
  if (Platform.environment['QUOTABOT_FIRST_RUN_FIXTURE'] != '1') {
    throw StateError('first-run fixture requires an isolated test environment');
  }
  final local = args.first == 'local';
  // An OS keyring is not isolated by HOME. Disable this provider in the
  // fixture's private quotabot state before any discovery can inspect it.
  final marker = ProviderDisconnectStore.markerFile('antigravity');
  marker.parent.createSync(recursive: true);
  marker.writeAsStringSync('{}');
  final unexpected = <String>[];
  await http.runWithClient(() => cli.main(args.skip(1).toList()), () {
    return MockClient((request) async {
      if (request.url.host != '127.0.0.1' ||
          request.headers.containsKey('authorization')) {
        unexpected.add('${request.method} ${request.url.host}');
        return http.Response('{}', 500);
      }
      if (local && request.url.port == 11434) {
        switch ((request.method, request.url.path)) {
          case ('GET', '/api/tags'):
          case ('GET', '/api/ps'):
            return http.Response(
                jsonEncode({
                  'models': [
                    {
                      'name': 'fixture:tiny',
                      'size': 1000000,
                      'context_length': 4096
                    }
                  ],
                }),
                200);
          case ('POST', '/api/show'):
            if (request.body != jsonEncode({'model': 'fixture:tiny'})) {
              unexpected.add('unexpected model metadata body');
            }
            return http.Response(
                jsonEncode({
                  'capabilities': ['completion'],
                  'model_info': {
                    'general.architecture': 'llama',
                    'llama.context_length': 4096
                  },
                }),
                200);
        }
      }
      if (request.method != 'GET') unexpected.add(request.method);
      return http.Response('{}', 404);
    });
  });
  if (unexpected.isNotEmpty) {
    throw StateError('unexpected first-run metadata request: $unexpected');
  }
}
