import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:quotabot_collector/auth/provider_disconnect.dart';
import 'package:test/test.dart';

import 'support/cli_process.dart';

/// End-to-end guard that `quotabot logout` removes every grant slot, not just
/// the provider-default one. Login persists an account-scoped grant too, and a
/// leftover account grant would be refreshed and reused after a disconnect.
void main() {
  late Directory temp;
  late Directory authDir;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_logout_cli_');
    authDir = Directory('${temp.path}/quotabot/auth')
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File defaultSlot(String provider) => File('${authDir.path}/$provider.json');

  File disconnectMarker(String provider) =>
      File('${authDir.path}/$provider.disconnected');

  File accountSlot(String provider, String account) {
    final hash = sha256.convert(utf8.encode(account)).toString();
    return File('${authDir.path}/${provider}_account_$hash.json');
  }

  test('logout removes default, account, and ownerless grant slots', () async {
    final def = defaultSlot('grok')..writeAsStringSync('{"access_token":"d"}');
    final acct = accountSlot('grok', 'work@example.com')
      ..writeAsStringSync('{"access_token":"a","_account":"work@example.com"}');
    final ownerless = accountSlot('grok', 'legacy@example.com')
      ..writeAsStringSync('{"access_token":"legacy"}');
    expect(def.existsSync(), isTrue);
    expect(acct.existsSync(), isTrue);
    expect(ownerless.existsSync(), isTrue);

    final result = await runCollectCli(
      ['logout', 'grok'],
      environment: {
        'LOCALAPPDATA': temp.path,
        'XDG_CONFIG_HOME': temp.path,
      },
    );

    expectExitCode(result, 0);
    expect(def.existsSync(), isFalse, reason: 'default grant must be cleared');
    expect(acct.existsSync(), isFalse, reason: 'account grant must be cleared');
    expect(
      ownerless.existsSync(),
      isFalse,
      reason: 'ownerless account grant must be cleared',
    );
    expect(disconnectMarker('grok').existsSync(), isTrue);
    expect(result.stderr, contains('Host credentials were left unchanged'));
  });

  test('logout keeps every provider disconnected despite host credentials',
      () async {
    final home = Directory('${temp.path}/home')..createSync();
    final grokAuth = File('${home.path}/.grok/auth.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'work': {'email': 'work@example.com', 'key': 'host-grok-token'},
      }));
    final claudeAuth = File('${home.path}/.claude/.credentials.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'claudeAiOauth': {
          'accessToken': 'host-claude-token',
          'refreshToken': 'host-claude-refresh',
          'expiresAt': DateTime.now().millisecondsSinceEpoch + 3600000,
        },
      }));
    final codexAuth = File('${home.path}/.codex/auth.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'tokens': {
          'access_token': 'host-codex-token',
          'refresh_token': 'host-codex-refresh',
          'account_id': 'host-account',
        },
      }));
    expect(grokAuth.existsSync(), isTrue);
    expect(claudeAuth.existsSync(), isTrue);
    expect(codexAuth.existsSync(), isTrue);
    final env = {
      'LOCALAPPDATA': temp.path,
      'XDG_CONFIG_HOME': temp.path,
      'USERPROFILE': home.path,
      'HOME': home.path,
      'APPDATA': '${temp.path}/appdata',
      'XDG_DATA_HOME': '${temp.path}/data',
    };

    for (final provider in ['grok', 'antigravity', 'claude', 'codex']) {
      final logout = await runCollectCli(
        ['logout', provider],
        environment: env,
      );
      expectExitCode(logout, 0);
      expect(disconnectMarker(provider).existsSync(), isTrue);

      final check = await runCollectCli(
        ['check', provider, '--json'],
        environment: env,
      );
      expectExitCode(check, 69);
      final body = jsonDecode(check.stdout as String) as Map<String, dynamic>;
      expect(body['error'], providerDisconnectedMessage(provider));
      expect(body['available'], isFalse);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('logout and login reject an unknown provider with the usage exit code',
      () async {
    final env = {'LOCALAPPDATA': temp.path, 'XDG_CONFIG_HOME': temp.path};
    // Documented: 64 = bad arguments or an unknown provider. These previously
    // printed usage but returned 0, so a wrapper saw a rejected command succeed.
    expectExitCode(
        await runCollectCli(['logout', 'bogus'], environment: env), 64);
    expectExitCode(
        await runCollectCli(['login', 'bogus'], environment: env), 64);
  });
}
