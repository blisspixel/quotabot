import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

  File accountSlot(String provider, String account) {
    final hash = sha256.convert(utf8.encode(account)).toString();
    return File('${authDir.path}/${provider}_account_$hash.json');
  }

  test('logout removes both the default and account grant slots', () async {
    final def = defaultSlot('grok')..writeAsStringSync('{"access_token":"d"}');
    final acct = accountSlot('grok', 'work@example.com')
      ..writeAsStringSync('{"access_token":"a","_account":"work@example.com"}');
    expect(def.existsSync(), isTrue);
    expect(acct.existsSync(), isTrue);

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
  });

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
