import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/grok.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/auth/xai_auth.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late File authFile;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quotabot_grok_adapter_');
    authFile = File('${temp.path}/auth.json');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  void writeAuth(Map<String, dynamic> body) {
    authFile.writeAsStringSync(jsonEncode(body));
  }

  Uint8List grokMessage(double percent, int timestamp) {
    final out = <int>[0x0d];
    final f = ByteData(4)..setFloat32(0, percent, Endian.little);
    out.addAll(f.buffer.asUint8List());
    out.add(0x20);
    var t = timestamp;
    while (true) {
      final b = t & 0x7f;
      t >>= 7;
      if (t == 0) {
        out.add(b);
        break;
      }
      out.add(b | 0x80);
    }
    return Uint8List.fromList(out);
  }

  Uint8List grpcFrame(Uint8List payload) {
    final len = payload.length;
    return Uint8List.fromList([
      0,
      (len >> 24) & 0xff,
      (len >> 16) & 0xff,
      (len >> 8) & 0xff,
      len & 0xff,
      ...payload,
    ]);
  }

  test('collectAccounts reads every account in auth.json', () async {
    writeAuth({
      'a': {'email': 'a@example.com', 'key': 'token-a'},
      'b': {'email': 'b@example.com', 'key': 'token-b'},
    });
    final tokens = <String>[];
    final resolverCalls = <String>[];
    final q = await GrokAdapter(
      authFile: authFile,
      tokenResolver: (account, allowDefault) async {
        resolverCalls.add('$account:$allowDefault');
        return null;
      },
      usageFetcher: (token, asOf) async {
        tokens.add(token);
        return QuotaWindow(
          label: 'monthly',
          usedPercent: token.endsWith('a') ? 10 : 20,
        );
      },
    ).collectAccounts();

    expect(q.map((p) => p.account).toList(), [
      'a@example.com',
      'b@example.com',
    ]);
    expect(q.map((p) => p.windows.single.usedPercent).toList(), [10, 20]);
    expect(tokens, ['token-a', 'token-b']);
    // With more than one account, the default grant is offered to none of them,
    // so neither resolver call permits it.
    expect(resolverCalls, ['a@example.com:false', 'b@example.com:false']);
  });

  test('collect returns the first account snapshot', () async {
    writeAuth({
      'a': {'email': 'a@example.com', 'key': 'token-a'},
      'b': {'email': 'b@example.com', 'key': 'token-b'},
    });

    final q = await GrokAdapter(
      authFile: authFile,
      tokenResolver: (_, __) async => null,
      usageFetcher: (_, __) async =>
          QuotaWindow(label: 'monthly', usedPercent: 12),
    ).collect();

    expect(q.account, 'a@example.com');
    expect(q.windows.single.usedPercent, 12);
  });

  test('account grant wins before the CLI token', () async {
    writeAuth({
      'a': {'email': 'a@example.com', 'key': 'token-a'},
      'b': {'email': 'b@example.com', 'key': 'token-b'},
    });
    final tokens = <String>[];

    final q = await GrokAdapter(
      authFile: authFile,
      tokenResolver: (account, _) async =>
          account == 'a@example.com' ? 'own-a' : null,
      usageFetcher: (token, asOf) async {
        tokens.add(token);
        return QuotaWindow(label: 'monthly', usedPercent: 5);
      },
    ).collectAccounts();

    expect(q.length, 2);
    expect(tokens, ['own-a', 'token-b']);
  });

  test('the default grant is never lent across multiple accounts', () async {
    // With several accounts the ownerless default grant must not stand in for
    // any of them: account a would otherwise be read under b's or another
    // account's token and mislabeled. Only b, which has its own slot, reads.
    TokenStore.clear(XaiAuth.provider);
    TokenStore.clearAccounts(XaiAuth.provider);
    addTearDown(() {
      TokenStore.clear(XaiAuth.provider);
      TokenStore.clearAccounts(XaiAuth.provider);
    });
    final expiry = nowEpoch() + 3600;
    TokenStore.save(
      XaiAuth.provider,
      Tokens(accessToken: 'default-token', expiresAt: expiry),
    );
    TokenStore.save(
      XaiAuth.provider,
      Tokens(accessToken: 'b-token', expiresAt: expiry),
      account: 'b@example.com',
    );
    writeAuth({
      'a': {'email': 'a@example.com'},
      'b': {'email': 'b@example.com'},
      'c': {'email': 'c@example.com'},
    });
    final tokens = <String>[];

    final q = await GrokAdapter(
      authFile: authFile,
      usageFetcher: (token, asOf) async {
        tokens.add(token);
        return QuotaWindow(label: 'monthly', usedPercent: 9);
      },
    ).collectAccounts();

    expect(tokens, ['b-token']);
    expect(q.map((p) => p.account).toList(), [
      'a@example.com',
      'b@example.com',
      'c@example.com',
    ]);
    expect(q.first.error, 'no token - run: quotabot login grok');
    expect(q.last.error, 'no token - run: quotabot login grok');
  });

  test('the default grant stands in for a single account', () async {
    TokenStore.clear(XaiAuth.provider);
    TokenStore.clearAccounts(XaiAuth.provider);
    addTearDown(() {
      TokenStore.clear(XaiAuth.provider);
      TokenStore.clearAccounts(XaiAuth.provider);
    });
    TokenStore.save(
      XaiAuth.provider,
      Tokens(accessToken: 'default-token', expiresAt: nowEpoch() + 3600),
    );
    writeAuth({
      'a': {'email': 'a@example.com'},
    });
    final tokens = <String>[];

    final q = await GrokAdapter(
      authFile: authFile,
      usageFetcher: (token, asOf) async {
        tokens.add(token);
        return QuotaWindow(label: 'monthly', usedPercent: 9);
      },
    ).collectAccounts();

    expect(tokens, ['default-token']);
    expect(q.single.account, 'a@example.com');
    expect(q.single.windows.single.usedPercent, 9);
  });

  test('a default grant stamped for another account is not lent out', () async {
    TokenStore.clear(XaiAuth.provider);
    TokenStore.clearAccounts(XaiAuth.provider);
    addTearDown(() {
      TokenStore.clear(XaiAuth.provider);
      TokenStore.clearAccounts(XaiAuth.provider);
    });
    // The default grant belongs to account a, but the CLI now holds only
    // account b. b must read with its own CLI token, never a's default grant,
    // or b's row would show a's usage.
    TokenStore.saveDefaultOwnedBy(
      XaiAuth.provider,
      Tokens(accessToken: 'a-default', expiresAt: nowEpoch() + 3600),
      'a@example.com',
    );
    writeAuth({
      'b': {'email': 'b@example.com', 'key': 'token-b'},
    });
    final tokens = <String>[];

    final q = await GrokAdapter(
      authFile: authFile,
      usageFetcher: (token, asOf) async {
        tokens.add(token);
        return QuotaWindow(label: 'monthly', usedPercent: 4);
      },
    ).collectAccounts();

    expect(tokens, ['token-b']);
    expect(q.single.account, 'b@example.com');
  });

  test('a default grant stamped for the sole account is lent to it', () async {
    TokenStore.clear(XaiAuth.provider);
    TokenStore.clearAccounts(XaiAuth.provider);
    addTearDown(() {
      TokenStore.clear(XaiAuth.provider);
      TokenStore.clearAccounts(XaiAuth.provider);
    });
    TokenStore.saveDefaultOwnedBy(
      XaiAuth.provider,
      Tokens(accessToken: 'a-default', expiresAt: nowEpoch() + 3600),
      'a@example.com',
    );
    writeAuth({
      'a': {
        'email': 'a@example.com'
      }, // no CLI key: relies on the default grant
    });
    final tokens = <String>[];

    final q = await GrokAdapter(
      authFile: authFile,
      usageFetcher: (token, asOf) async {
        tokens.add(token);
        return QuotaWindow(label: 'monthly', usedPercent: 4);
      },
    ).collectAccounts();

    expect(tokens, ['a-default']);
    expect(q.single.account, 'a@example.com');
  });

  test('expired billing tokens keep the account visible', () async {
    writeAuth({
      'a': {'email': 'a@example.com', 'key': 'token-a'},
    });

    final q = await GrokAdapter(
      authFile: authFile,
      tokenResolver: (_, __) async => null,
      usageFetcher: (_, __) async => null,
    ).collectAccounts();

    expect(q.single.account, 'a@example.com');
    expect(q.single.ok, isTrue);
    expect(q.single.windows, isEmpty);
    expect(
        q.single.error, 'token expired (open Grok to refresh) - account only');
  });

  test('fetches Grok billing metadata over gRPC-web', () async {
    writeAuth({
      'a': {'email': 'a@example.com', 'key': 'token-a'},
    });
    const now = 1782000000;
    final client = MockClient((req) async {
      expect(req.method, 'POST');
      expect(req.headers['Authorization'], 'Bearer token-a');
      expect(req.headers['Content-Type'], 'application/grpc-web+proto');
      expect(req.headers['x-grpc-web'], '1');
      expect(req.bodyBytes, [0, 0, 0, 0, 0]);
      return http.Response.bytes(
        grpcFrame(grokMessage(17.0, now + 3600)),
        200,
        headers: {'grpc-status': '0'},
      );
    });

    final q = await GrokAdapter(
      authFile: authFile,
      tokenResolver: (_, __) async => null,
      client: client,
    ).collectAccounts();

    expect(q.single.windows.single.usedPercent, 17);
    expect(q.single.windows.single.resetsAt, now + 3600);
  });

  test('non-ok Grok billing responses are plain account-only notes', () async {
    writeAuth({
      'a': {'email': 'a@example.com', 'key': 'token-a'},
      'b': {'email': 'b@example.com', 'key': 'token-b'},
    });
    var calls = 0;
    final client = MockClient((_) async {
      calls += 1;
      if (calls == 1) return http.Response('denied', 403);
      return http.Response.bytes(
        Uint8List.fromList([0, 0, 0, 0, 0]),
        200,
        headers: {'grpc-status': '16'},
      );
    });

    final q = await GrokAdapter(
      authFile: authFile,
      tokenResolver: (_, __) async => null,
      client: client,
    ).collectAccounts();

    expect(q, hasLength(2));
    expect(
      q.map((p) => p.error).toSet(),
      {'token expired (open Grok to refresh) - account only'},
    );
  });

  test('an account without any token stays visible with a plain note',
      () async {
    writeAuth({
      'a': {'email': 'a@example.com'},
    });

    final q = await GrokAdapter(
      authFile: authFile,
      tokenResolver: (_, __) async => null,
      usageFetcher: (_, __) async => throw StateError('must not fetch'),
    ).collectAccounts();

    expect(q.single.account, 'a@example.com');
    expect(q.single.ok, isTrue);
    expect(q.single.windows, isEmpty);
    expect(q.single.error, 'no token - run: quotabot login grok');
  });

  test('missing, empty, and malformed auth files return plain errors',
      () async {
    final missing = await GrokAdapter(
      authFile: File('${temp.path}/missing.json'),
    ).collectAccounts();
    expect(missing.single.ok, isFalse);
    expect(missing.single.error, 'no ~/.grok/auth.json');

    writeAuth({});
    final empty = await GrokAdapter(authFile: authFile).collectAccounts();
    expect(empty.single.ok, isFalse);
    expect(empty.single.error, 'no grok account');

    authFile.writeAsStringSync('{');
    final malformed = await GrokAdapter(authFile: authFile).collectAccounts();
    expect(malformed.single.ok, isFalse);
    expect(malformed.single.error, 'unable to read Grok usage');
  });

  test('duplicate or malformed account entries are ignored', () async {
    writeAuth({
      'a': {'email': 'a@example.com', 'key': 'token-a'},
      'dup': {'email': 'a@example.com', 'key': 'token-dup'},
      'bad': 'not an account',
      'default': {'key': 'token-default'},
    });

    final q = await GrokAdapter(
      authFile: authFile,
      tokenResolver: (_, __) async => null,
      usageFetcher: (_, __) async =>
          QuotaWindow(label: 'monthly', usedPercent: 1),
    ).collectAccounts();

    expect(q.map((p) => p.account).toList(), ['a@example.com', 'default']);
  });
}
