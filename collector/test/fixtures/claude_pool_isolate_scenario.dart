import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/adapters/claude.dart';
import 'package:quotabot_collector/analysis.dart';
import 'package:quotabot_collector/auth/tokens.dart';
import 'package:quotabot_collector/collector.dart';
import 'package:quotabot_collector/credential_pool_store.dart';
import 'package:quotabot_collector/drift.dart';
import 'package:quotabot_collector/provider_read_gate.dart';
import 'package:quotabot_collector/util.dart';

const _hostGeneration = 'synthetic-host-generation';
const _grantGeneration = 'synthetic-grant-generation';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw StateError('fixture requires root and scenario');
  }
  final root = Directory(arguments[0]);
  final profile = Directory('${root.path}/profile');
  if (home() != profile.path) {
    throw StateError('fixture requires isolated home');
  }
  setQuotabotDirOverrideForTesting(Directory('${root.path}/data'));
  final auth = File('${profile.path}/.claude/.credentials.json');
  void writeHost(String generation) {
    auth.parent.createSync(recursive: true);
    auth.writeAsStringSync(jsonEncode({
      'claudeAiOauth': {
        'accessToken': 'synthetic-host-access',
        'refreshToken': generation,
        'expiresAt': (nowEpoch() + 3600) * 1000,
        'subscriptionType': 'max',
      },
    }));
  }

  writeHost(_hostGeneration);
  final hostIdentity = opaqueCredentialIdentity('claude', _hostGeneration);
  final scenario = arguments[1];
  final multiple = scenario == 'unproved-pools';
  final first = await _collect(root.path, auth.path,
      profileAccount: 'pool-a', multiple: multiple);
  final firstHost = first.first;
  final samples = jsonEncode(loadBuckets('claude',
          account: firstHost.account, fallbackToProvider: false)
      .map((bucket) => bucket.toJson())
      .toList());

  Map<String, Object?> result;
  switch (scenario) {
    case 'recover':
      // Cross a real second so an accidentally renewed cache timestamp fails.
      await Future<void>.delayed(const Duration(seconds: 1));
      final failed =
          (await _collect(root.path, auth.path, usageStatus: 429)).single;
      result = {
        'first_trusted': isTrustedQuotaEvidenceAt(firstHost, nowEpoch()),
        'association_saved':
            CredentialPoolStore('claude').lookup(hostIdentity)?.pool ==
                firstHost.account,
        'same_account': failed.account == firstHost.account,
        'stale': failed.stale,
        'available': providerAvailability(failed, nowEpoch()).available,
        'original_capture': failed.asOf == firstHost.asOf,
        'windows_preserved': jsonEncode(
                failed.windows.map((window) => window.toJson()).toList()) ==
            jsonEncode(
                firstHost.windows.map((window) => window.toJson()).toList()),
        'analytics_unchanged': samples ==
            jsonEncode(loadBuckets('claude',
                    account: firstHost.account, fallbackToProvider: false)
                .map((bucket) => bucket.toJson())
                .toList()),
        'http_status': failed.httpStatus,
      };
    case 'replacement':
      writeHost('synthetic-replacement');
      final replacement =
          await _collect(root.path, auth.path, usageStatus: 429);
      auth.deleteSync();
      final signedOut = await _collect(root.path, auth.path, usageStatus: 429);
      result = {
        'replacement_has_old_pool':
            replacement.any((quota) => quota.account == firstHost.account),
        'replacement_stale': replacement.any((quota) => quota.stale),
        'replacement_has_windows': replacement.any((quota) => quota.hasWindows),
        'signed_out_has_old_pool':
            signedOut.any((quota) => quota.account == firstHost.account),
        'signed_out_current_accounts': ClaudeAdapter.currentAccounts.length,
      };
    case 'account-change':
      final changed =
          (await _collect(root.path, auth.path, profileAccount: 'pool-b'))
              .single;
      final failed = await _collect(root.path, auth.path, usageStatus: 429);
      result = {
        'account_changed': changed.account != firstHost.account,
        'new_account_trusted': isTrustedQuotaEvidenceAt(changed, nowEpoch()),
        'failed_lookup_uses_new_account':
            failed.single.account == changed.account,
        'old_account_returned':
            failed.any((quota) => quota.account == firstHost.account),
        'failed_lookup_stale': failed.single.stale,
      };
    case 'alias':
      final unproved = await _collect(root.path, auth.path);
      result = {
        'rows': unproved.length,
        'fresh': isTrustedQuotaEvidenceAt(unproved.first, nowEpoch()),
        'credential_account': unproved.first.account == hostIdentity,
        'borrowed_old_pool':
            unproved.any((quota) => quota.account == firstHost.account),
      };
    case 'unproved-pools':
      final unproved = await _collect(root.path, auth.path, multiple: true);
      final fresh = unproved
          .where((quota) => isTrustedQuotaEvidenceAt(quota, nowEpoch()))
          .toList();
      result = {
        'initial_proven_pools': first.length,
        'fresh_rows': fresh.length,
        'fresh_uses_credential': fresh.single.account == hostIdentity,
        'duplicate_host_alias':
            unproved.any((quota) => quota.account == firstHost.account),
        'other_stale_alias_retained': unproved
            .any((quota) => quota.stale && quota.account == first.last.account),
      };
    default:
      throw StateError('unknown synthetic scenario');
  }
  stdout.writeln(jsonEncode(result));
}

Future<List<ProviderQuota>> _collect(
  String root,
  String auth, {
  String? profileAccount,
  int usageStatus = 200,
  bool multiple = false,
}) =>
    Isolate.run(() async {
      setQuotabotDirOverrideForTesting(Directory('$root/data'));
      final grant = ClaudeCredential(
          accessToken: 'synthetic-grant-access',
          identity: opaqueCredentialIdentity('claude', _grantGeneration));
      if (multiple) {
        // This is quotabot-owned synthetic discovery metadata, never host state.
        TokenStore.saveDefaultOwnedBy(
            'claude',
            Tokens(
              accessToken: grant.accessToken,
              refreshToken: _grantGeneration,
              expiresAt: nowEpoch() + 3600,
            ),
            grant.identity);
      }
      final adapter = ClaudeAdapter(
        credentialsFile: File(auth),
        grantCredential: () async => multiple ? grant : null,
        readGate: ProviderReadGate(
          directory: Directory('$root/gates'),
          jitter: (_) => 0,
          hardenDirectory: (_) {},
          hardenFile: (_) {},
        ),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/profile')) {
            if (profileAccount == null) {
              return http.Response('{}', 503, headers: {'retry-after': '120'});
            }
            final isGrant = request.headers['Authorization'] ==
                'Bearer synthetic-grant-access';
            return http.Response(
                jsonEncode({
                  'account': {
                    'uuid': isGrant ? 'grant-pool' : profileAccount,
                    'has_claude_max': true,
                    'has_claude_pro': false,
                  }
                }),
                200);
          }
          if (usageStatus != 200) {
            return http.Response('{}', usageStatus,
                headers: {'retry-after': '120'});
          }
          final now = nowEpoch();
          String reset(int seconds) =>
              DateTime.fromMillisecondsSinceEpoch((now + seconds) * 1000,
                      isUtc: true)
                  .toIso8601String();
          return http.Response(
              jsonEncode({
                'five_hour': {'utilization': 30, 'resets_at': reset(3600)},
                'seven_day': {'utilization': 20, 'resets_at': reset(7200)},
              }),
              200);
        }),
      );
      final snapshot = await collectAllWithRuntimeAccess(registry: [
        ProviderAdapterRegistration(
          id: 'claude',
          displayName: 'Claude',
          adapterClass: ProviderAdapterClass.subscription,
          sourceClasses: kAuthoritativeLiveSourceClasses,
          collect: () => collectClaudeProviderAccounts(adapter),
          multiAccount: true,
          currentAccounts: () => ClaudeAdapter.currentAccounts,
          fixtureKind: ProviderFixtureKind.claudeUsage,
          fixtureFile: 'claude_usage.json',
        )
      ]);
      await ProviderReadGate.drainActive();
      return snapshot.providers;
    });
