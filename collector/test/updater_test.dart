import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quotabot_collector/updater.dart';
import 'package:test/test.dart';

Map<String, Object?> release(
  String tag, {
  bool? prerelease,
  bool draft = false,
}) =>
    {
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease ?? tag.contains('-'),
    };

MockClient releasesClient(List<Object?> releases) =>
    MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.host, 'api.github.com');
      expect(request.headers['user-agent'], startsWith('quotabot/'));
      if (request.url.path.startsWith(
        '/repos/blisspixel/quotabot/releases/tags/',
      )) {
        final tag = request.url.pathSegments.last;
        final matching = releases.where(
          (row) => row is Map && row['tag_name'] == tag,
        );
        if (matching.isEmpty) return http.Response('', 404);
        return http.Response(jsonEncode(matching.first), 200);
      }
      if (request.url.path == '/repos/blisspixel/quotabot/releases/latest') {
        final matching = releases.where(
          (row) =>
              row is Map && row['draft'] == false && row['prerelease'] == false,
        );
        if (matching.isEmpty) return http.Response('', 404);
        return http.Response(jsonEncode(matching.first), 200);
      }
      expect(request.url.path, '/repos/blisspixel/quotabot/releases');
      expect(request.url.queryParameters['per_page'], '5');
      expect(request.url.queryParameters['page'], '1');
      return http.Response(jsonEncode(releases), 200);
    });

void main() {
  test('desktop archive advice only names shipped architectures', () {
    for (final row in [
      ('linux', 'x64', 'quotabot-linux-x64-desktop.tar.gz'),
      ('macos', 'arm64', 'quotabot-darwin-arm64-desktop.zip'),
      ('windows', 'x64', 'quotabot-windows-x64-desktop.zip'),
      ('linux', 'arm64', ''),
      ('macos', 'x64', ''),
      ('windows', 'arm64', ''),
    ]) {
      expect(
        portableDesktopAssetName(operatingSystem: row.$1, architecture: row.$2),
        row.$3,
      );
    }
  });

  group('QuotabotVersion', () {
    test('parses and orders stable and release-candidate versions', () {
      final rc9 = QuotabotVersion.tryParse('v0.10.0-rc.9')!;
      final rc16 = QuotabotVersion.tryParse('0.10.0-rc.16')!;
      final stable = QuotabotVersion.tryParse('0.10.0')!;

      expect(rc9.tag, 'v0.10.0-rc.9');
      expect(rc16.compareTo(rc9), greaterThan(0));
      expect(stable.compareTo(rc16), greaterThan(0));
      expect(stable.isPrerelease, isFalse);
    });

    test('rejects loose, ambiguous, and unsupported versions', () {
      for (final value in [
        '',
        'version 1.0.0',
        '01.0.0',
        '1.0',
        '1.0.0-beta.1',
        'v1.0.0-rc.01',
        ' v1.0.0',
        'v${'9' * 100}.0.0',
      ]) {
        expect(QuotabotVersion.tryParse(value), isNull, reason: value);
      }
    });
  });

  group('release discovery', () {
    test('uses an explicit GitHub token without exposing it in errors',
        () async {
      const token = 'github-test-token';
      final authenticated = MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer $token');
        return http.Response(jsonEncode(release('v0.9.9')), 200);
      });
      final check = await checkForQuotabotUpdate(
        currentVersion: '0.9.8',
        channel: UpdateChannel.stable,
        githubToken: ' $token ',
        client: authenticated,
      );
      expect(check.target.tag, 'v0.9.9');

      final unauthenticated = MockClient((request) async {
        expect(request.headers, isNot(contains('authorization')));
        return http.Response(jsonEncode(release('v0.9.9')), 200);
      });
      await checkForQuotabotUpdate(
        currentVersion: '0.9.8',
        channel: UpdateChannel.stable,
        client: unauthenticated,
      );

      await expectLater(
        checkForQuotabotUpdate(
          currentVersion: '0.9.8',
          channel: UpdateChannel.stable,
          githubToken: 'secret\nvalue',
          client: releasesClient([release('v0.9.9')]),
        ),
        throwsA(
          isA<QuotabotUpdateException>()
              .having(
                (error) => error.message,
                'message',
                contains('token is invalid'),
              )
              .having(
                (error) => error.message,
                'message',
                isNot(contains('secret')),
              ),
        ),
      );
    });

    test('release candidates follow the newest preview by default', () async {
      final check = await checkForQuotabotUpdate(
        currentVersion: '0.10.0-rc.14',
        channel: UpdateChannel.preview,
        client: releasesClient([
          release('v0.9.9'),
          release('v0.10.0-rc.15'),
          release('v0.10.0-rc.16'),
          release('v0.10.0-rc.17', draft: true),
        ]),
      );

      expect(check.target.tag, 'v0.10.0-rc.16');
      expect(check.updateAvailable, isTrue);
      expect(check.toJson()['schema'], quotabotUpdateSchema);
      expect(check.toJson()['selection'], 'channel');
    });

    test('release candidate preview channel promotes to the final stable',
        () async {
      final check = await checkForQuotabotUpdate(
        currentVersion: '0.10.0-rc.17',
        channel: UpdateChannel.preview,
        client: releasesClient([
          release('v0.9.9'),
          release('v0.10.0-rc.17'),
          release('v0.10.0'),
        ]),
      );

      expect(check.target.tag, 'v0.10.0');
      expect(check.updateAvailable, isTrue);
      expect(check.toJson()['selection'], 'channel');
    });

    test('stable channel does not admit a preview', () async {
      final check = await checkForQuotabotUpdate(
        currentVersion: '0.9.8',
        channel: UpdateChannel.stable,
        client: releasesClient([
          release('v0.9.9'),
          release('v0.10.0-rc.16'),
        ]),
      );

      expect(check.target.tag, 'v0.9.9');
      expect(check.updateAvailable, isTrue);
    });

    test('stable discovery uses GitHub latest without listing releases',
        () async {
      final client = MockClient((request) async {
        expect(
          request.url.path,
          '/repos/blisspixel/quotabot/releases/latest',
        );
        expect(request.url.query, isEmpty);
        return http.Response(jsonEncode(release('v0.10.1')), 200);
      });

      final check = await checkForQuotabotUpdate(
        currentVersion: '0.10.0',
        channel: UpdateChannel.stable,
        client: client,
      );

      expect(check.target.tag, 'v0.10.1');
      expect(check.updateAvailable, isTrue);
    });

    test('preview discovery follows bounded small-page pagination', () async {
      final client = MockClient((request) async {
        expect(request.url.queryParameters['per_page'], '5');
        final page = request.url.queryParameters['page'];
        if (page == '1') {
          return http.Response(
            jsonEncode([
              for (var rc = 20; rc >= 16; rc--) release('v0.10.0-rc.$rc'),
            ]),
            200,
          );
        }
        expect(page, '2');
        return http.Response(
          jsonEncode([
            release('v0.10.0-rc.21'),
            release('v0.9.9'),
          ]),
          200,
        );
      });

      final check = await checkForQuotabotUpdate(
        currentVersion: '0.10.0-rc.15',
        channel: UpdateChannel.preview,
        client: client,
      );

      expect(check.target.tag, 'v0.10.0-rc.21');
    });

    test('exact target must be a published matching release', () async {
      final check = await checkForQuotabotUpdate(
        currentVersion: '0.10.0-rc.16',
        channel: UpdateChannel.preview,
        targetTag: 'v0.9.9',
        client: releasesClient([release('v0.9.9')]),
      );
      expect(check.target.tag, 'v0.9.9');
      expect(check.updateAvailable, isFalse);
      expect(check.channel, isNull);
      expect(check.toJson()['selection'], 'exact');
      expect(check.toJson(), isNot(contains('channel')));

      await expectLater(
        checkForQuotabotUpdate(
          currentVersion: '0.10.0-rc.16',
          channel: UpdateChannel.preview,
          targetTag: 'v0.9.8',
          client: releasesClient([release('v0.9.9')]),
        ),
        throwsA(
          isA<QuotabotUpdateException>().having(
            (error) => error.message,
            'message',
            contains('no published quotabot release'),
          ),
        ),
      );

      await expectLater(
        checkForQuotabotUpdate(
          currentVersion: '0.10.0-rc.16',
          channel: UpdateChannel.preview,
          targetTag: '0.9.9',
          client: releasesClient([release('v0.9.9')]),
        ),
        throwsA(
          isA<QuotabotUpdateException>().having(
            (error) => error.message,
            'message',
            contains('--target must be'),
          ),
        ),
      );
    });

    test('ignores malformed and inconsistently classified releases', () async {
      final check = await checkForQuotabotUpdate(
        currentVersion: '0.9.8',
        channel: UpdateChannel.preview,
        client: releasesClient([
          release('v0.10.0-rc.99', prerelease: false),
          release('not-a-version'),
          {'tag_name': 'v0.10.0-rc.98', 'draft': false},
          release('v0.9.9'),
        ]),
      );

      expect(check.target.tag, 'v0.9.9');
    });

    test('bounds status, structure, JSON, size, and timeout failures',
        () async {
      final cases = <({MockClient client, String message})>[
        (
          client: MockClient((_) async => http.Response('', 503)),
          message: 'HTTP 503',
        ),
        (
          client: MockClient((_) async => http.Response('[]', 200)),
          message: 'unexpected document',
        ),
        (
          client: MockClient((_) async => http.Response('{', 200)),
          message: 'invalid JSON',
        ),
        (
          client: MockClient(
            (_) async => http.Response.bytes(
              List<int>.filled(512 * 1024 + 1, 32),
              200,
            ),
          ),
          message: 'size limit',
        ),
        (
          client: MockClient((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return http.Response('[]', 200);
          }),
          message: 'timed out',
        ),
      ];
      for (final item in cases) {
        await expectLater(
          checkForQuotabotUpdate(
            currentVersion: '0.9.9',
            channel: UpdateChannel.stable,
            client: item.client,
            timeout: const Duration(milliseconds: 5),
          ),
          throwsA(
            isA<QuotabotUpdateException>().having(
              (error) => error.message,
              'message',
              contains(item.message),
            ),
          ),
        );
      }
    });
  });

  test('Windows invocation uses only the bundled installer and exact tag',
      () async {
    if (!Platform.isWindows) return;
    final temp = Directory.systemTemp.createTempSync('quotabot_updater_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final bundle = Directory('${temp.path}${Platform.pathSeparator}bundle');
    final bin = Directory('${bundle.path}${Platform.pathSeparator}bin')
      ..createSync(recursive: true);
    final lib = Directory('${bundle.path}${Platform.pathSeparator}lib')
      ..createSync(recursive: true);
    final executable = File('${bin.path}${Platform.pathSeparator}quotabot.exe')
      ..writeAsBytesSync([1]);
    File('${lib.path}${Platform.pathSeparator}install.ps1')
        .writeAsStringSync('exit 0');
    final systemRoot = Directory(
      '${temp.path}${Platform.pathSeparator}Windows',
    );
    final powershell = File(
      '${systemRoot.path}${Platform.pathSeparator}System32'
      '${Platform.pathSeparator}WindowsPowerShell${Platform.pathSeparator}v1.0'
      '${Platform.pathSeparator}powershell.exe',
    )..createSync(recursive: true);
    final localAppData = '${temp.path}${Platform.pathSeparator}Local';

    final invocation = packagedInstallerInvocation(
      currentExecutable: executable.path,
      operatingSystem: 'windows',
      targetTag: 'v0.10.0-rc.16',
      environment: {
        'SystemRoot': systemRoot.path,
        'LOCALAPPDATA': localAppData,
      },
    );

    expect(invocation.executable, powershell.path);
    expect(invocation.arguments, containsAllInOrder(['-File', isA<String>()]));
    expect(invocation.arguments.last, endsWith('lib\\install.ps1'));
    expect(invocation.environment['QUOTABOT_VERSION'], 'v0.10.0-rc.16');
    expect(invocation.environment['QUOTABOT_REPO'], 'blisspixel/quotabot');
    expect(invocation.installedExecutable, endsWith('bin\\quotabot.exe'));
  });

  test('POSIX invocation uses only the bundled installer and exact tag',
      () async {
    if (Platform.isWindows) return;
    final temp = Directory.systemTemp.createTempSync('quotabot_updater_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final bundle = Directory('${temp.path}${Platform.pathSeparator}bundle');
    final bin = Directory('${bundle.path}${Platform.pathSeparator}bin')
      ..createSync(recursive: true);
    final lib = Directory('${bundle.path}${Platform.pathSeparator}lib')
      ..createSync(recursive: true);
    final executable = File('${bin.path}${Platform.pathSeparator}quotabot')
      ..writeAsBytesSync([1]);
    final installer = File('${lib.path}${Platform.pathSeparator}install.sh')
      ..writeAsStringSync('exit 0');

    final invocation = packagedInstallerInvocation(
      currentExecutable: executable.path,
      operatingSystem: Platform.isMacOS ? 'macos' : 'linux',
      targetTag: 'v0.10.0-rc.17',
      environment: {'HOME': temp.path},
    );

    expect(invocation.executable, anyOf('/bin/bash', '/usr/bin/bash'));
    expect(invocation.arguments, [installer.path]);
    expect(invocation.environment['QUOTABOT_VERSION'], 'v0.10.0-rc.17');
    expect(invocation.environment['QUOTABOT_REPO'], 'blisspixel/quotabot');
    expect(
      invocation.installedExecutable,
      '${temp.path}${Platform.pathSeparator}.local'
      '${Platform.pathSeparator}bin${Platform.pathSeparator}quotabot',
    );
  });

  group('portable desktop version skew', () {
    final separator = Platform.pathSeparator;

    String joinPath(String parent, List<String> parts) {
      var path = parent;
      for (final part in parts) {
        path = '$path$separator$part';
      }
      return path;
    }

    void writeBundle(String bundlePath, String version) {
      final versionFile = File(
        joinPath(bundlePath, ['data', 'flutter_assets', 'version.json']),
      )..parent.createSync(recursive: true);
      versionFile.writeAsStringSync(
        '{"app_name":"quotabot","version":"$version",'
        '"build_number":"68","package_name":"quotabot"}',
      );
      File(joinPath(bundlePath, ['quotabot'])).writeAsStringSync('bundle');
    }

    test('names a different hand-extracted bundle and does not change it', () {
      final temp = Directory.systemTemp.createTempSync(
        'quotabot_desktop_skew_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final bundle = joinPath(temp.path, [
        '.local',
        'share',
        'quotabot-desktop',
        'v0.11.13',
      ]);
      writeBundle(bundle, '0.11.13');
      final versionFile = File(
        joinPath(bundle, ['data', 'flutter_assets', 'version.json']),
      );
      final before = versionFile.readAsBytesSync();
      final cli = QuotabotVersion.tryParse('0.11.15')!;

      final skew = findPortableDesktopVersionSkew(
        cliVersion: cli,
        operatingSystem: 'linux',
        architecture: 'x64',
        home: temp.path,
      );

      expect(skew.lines, hasLength(1));
      expect(skew.lines.single, contains('Hand-extracted desktop 0.11.13'));
      expect(skew.lines.single, contains(bundle));
      expect(skew.lines.single, contains('differs from CLI 0.11.15'));
      expect(skew.lines.single, contains('was left in place'));
      expect(skew.lines.single, contains('quotabot-linux-x64-desktop.tar.gz'));
      expect(
        skew.lines.single,
        contains(
          'https://github.com/blisspixel/quotabot/releases/tag/v0.11.15',
        ),
      );
      expect(skew.lines.single, contains('verify the .sha256 sidecar'));
      expect(versionFile.readAsBytesSync(), before);
      expect(File(joinPath(bundle, ['quotabot'])).existsSync(), isTrue);
      final json = skew.toJson();
      final bundles = json['bundles']! as List<Object?>;
      expect((bundles.single! as Map)['location'], 'hand_extracted');
      expect((bundles.single! as Map)['version'], '0.11.13');
    });

    test('says nothing when the embedded version matches the CLI', () {
      final temp = Directory.systemTemp.createTempSync(
        'quotabot_desktop_skew_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      writeBundle(
        joinPath(temp.path, [
          '.local',
          'share',
          'quotabot-desktop',
          'v0.11.15',
        ]),
        '0.11.15+70',
      );

      final skew = findPortableDesktopVersionSkew(
        cliVersion: QuotabotVersion.tryParse('0.11.15')!,
        operatingSystem: 'linux',
        architecture: 'x64',
        home: temp.path,
      );

      expect(skew.hasNotices, isFalse);
      expect(skew.lines, isEmpty);
    });

    test('ignores an oversized or malformed version file', () {
      final temp = Directory.systemTemp.createTempSync(
        'quotabot_desktop_skew_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final oversized = joinPath(temp.path, [
        '.local',
        'share',
        'quotabot-desktop',
        'huge',
      ]);
      final malformed = joinPath(temp.path, [
        '.local',
        'share',
        'quotabot-desktop',
        'bad',
      ]);
      writeBundle(oversized, '0.11.13');
      writeBundle(malformed, '0.11.13');
      final pad = 'x' * 5000;
      final hugeFile = File(
        joinPath(oversized, ['data', 'flutter_assets', 'version.json']),
      )..writeAsStringSync('{"version":"0.11.13","pad":"$pad"}');
      File(
        joinPath(malformed, ['data', 'flutter_assets', 'version.json']),
      ).writeAsStringSync('{');

      final skew = findPortableDesktopVersionSkew(
        cliVersion: QuotabotVersion.tryParse('0.11.15')!,
        operatingSystem: 'linux',
        architecture: 'arm64',
        home: temp.path,
      );

      expect(skew.hasNotices, isFalse);
      expect(hugeFile.existsSync(), isTrue);
    });

    test('names a managed Windows bundle and a macOS plist fallback', () {
      final temp = Directory.systemTemp.createTempSync(
        'quotabot_desktop_skew_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final managed = joinPath(temp.path, ['quotabot', 'desktop']);
      Directory(managed).createSync(recursive: true);
      File(joinPath(managed, ['quotabot.exe'])).writeAsStringSync('exe');
      writeBundle(managed, '0.11.13');
      final macBundle = joinPath(temp.path, [
        'Applications',
        'quotabot-v0.11.12.app',
      ]);
      final plist = File(joinPath(macBundle, ['Contents', 'Info.plist']))
        ..parent.createSync(recursive: true);
      plist.writeAsStringSync(
        '<plist><dict><key>CFBundleShortVersionString</key>'
        '<string>0.11.12</string></dict></plist>',
      );

      final windows = findPortableDesktopVersionSkew(
        cliVersion: QuotabotVersion.tryParse('0.11.15')!,
        operatingSystem: 'windows',
        architecture: 'x64',
        localAppData: temp.path,
      );
      final macos = findPortableDesktopVersionSkew(
        cliVersion: QuotabotVersion.tryParse('0.11.15')!,
        operatingSystem: 'macos',
        architecture: 'arm64',
        home: temp.path,
      );

      expect(windows.lines.single, contains('Managed desktop 0.11.13'));
      expect(
        windows.lines.single,
        contains('quotabot-windows-x64-desktop.zip'),
      );
      expect(windows.lines.single, contains('quotabot update --force'));
      expect(macos.lines.single, contains('Hand-extracted desktop 0.11.12'));
      expect(macos.lines.single, contains(macBundle));
      expect(macos.lines.single, contains('quotabot-darwin-arm64-desktop.zip'));
      expect(plist.readAsStringSync(), contains('0.11.12'));
    });

    test('caps notices and does not report a bundle past the scan limit', () {
      final temp = Directory.systemTemp.createTempSync(
        'quotabot_desktop_skew_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final root = joinPath(temp.path, ['quotabot-desktop']);
      for (var index = 0; index < 9; index++) {
        writeBundle(joinPath(root, ['b$index']), '0.11.13');
      }
      final crowded = Directory.systemTemp.createTempSync(
        'quotabot_desktop_crowd_',
      );
      addTearDown(() => crowded.deleteSync(recursive: true));
      final crowdRoot = joinPath(crowded.path, ['quotabot-desktop']);
      for (var index = 0; index < portableDesktopScanLimit; index++) {
        Directory(
          joinPath(crowdRoot, ['a${index.toString().padLeft(2, '0')}']),
        ).createSync(recursive: true);
      }
      writeBundle(joinPath(crowdRoot, ['z-bundle']), '0.11.13');

      final shown = findPortableDesktopVersionSkew(
        cliVersion: QuotabotVersion.tryParse('0.11.15')!,
        operatingSystem: 'windows',
        architecture: 'x64',
        localAppData: temp.path,
      );
      final hidden = findPortableDesktopVersionSkew(
        cliVersion: QuotabotVersion.tryParse('0.11.15')!,
        operatingSystem: 'windows',
        architecture: 'x64',
        localAppData: crowded.path,
      );

      expect(shown.bundles, hasLength(portableDesktopNoticeLimit));
      expect(shown.omittedCount, 1);
      expect(shown.lines.last, contains('1 more desktop copy'));
      expect(hidden.hasNotices, isFalse);
      expect(
        File(
          joinPath(crowdRoot, [
            'z-bundle',
            'data',
            'flutter_assets',
            'version.json',
          ]),
        ).existsSync(),
        isTrue,
      );
    });
  });
}
