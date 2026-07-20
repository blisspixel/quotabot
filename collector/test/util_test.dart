import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  test('nowEpoch and home return sensible values', () {
    expect(nowEpoch(), greaterThan(1700000000));
    expect(home(), isNotEmpty);
  });

  group('retryAfterSeconds', () {
    test('parses delay seconds and rejects invalid values', () {
      expect(retryAfterSeconds('120'), 120);
      expect(retryAfterSeconds(' 0 '), 0);
      expect(retryAfterSeconds('-1'), isNull);
      expect(retryAfterSeconds('soon'), isNull);
      expect(retryAfterSeconds(null), isNull);
    });

    test('parses HTTP-date values relative to the supplied clock', () {
      expect(
        retryAfterSeconds(
          'Wed, 21 Oct 2015 07:28:00 GMT',
          now: 1445412420,
        ),
        60,
      );
      expect(
        retryAfterSeconds(
          'Wed, 21 Oct 2015 07:27:00 GMT',
          now: 1445412420,
        ),
        0,
      );
    });
  });

  group('findKey', () {
    test('finds a nested value', () {
      final tree = {
        'a': [
          {'b': 1},
          {'rate_limits': 42},
        ],
      };
      expect(findKey(tree, 'rate_limits'), 42);
    });

    test('returns null when absent', () {
      expect(findKey({'a': 1}, 'missing'), isNull);
    });

    test('bounds recursion depth so a deep tree cannot overflow the stack', () {
      // Build a tree deeper than the default guard and confirm the walk stops
      // (returns null) instead of recursing without bound.
      dynamic tree = {'target': 1};
      for (var i = 0; i < 500; i++) {
        tree = {'nest': tree};
      }
      expect(findKey(tree, 'target'), isNull);
      // A shallow tree still finds the value.
      expect(
          findKey({
            'a': {'target': 1}
          }, 'target'),
          1);
    });
  });

  group('readVarint', () {
    test('decodes a multi-byte varint', () {
      expect(readVarint([0xAC, 0x02], 0), (300, 2));
    });

    test('returns null on truncation', () {
      expect(readVarint([0x80], 0), (null, 1));
    });
  });

  group('protoStrings and asciiString', () {
    test('extracts a length-delimited string', () {
      final bytes = [0x0a, 5, ...utf8.encode('hello')];
      expect(protoStrings(bytes), contains('hello'));
    });

    test('asciiString rejects binary and short input', () {
      expect(asciiString([0x01]), isNull);
      expect(asciiString([0x00, 0x01, 0x02, 0x03]), isNull);
      expect(asciiString(utf8.encode('ok')), 'ok');
    });

    test('rejects a hostile length varint without throwing', () {
      // Decodes near 2^62; an addition-form bounds check would wrap negative
      // and throw in sublist.
      final hostile = [0x0a, 255, 255, 255, 255, 255, 255, 255, 255, 0x7f];
      expect(protoStrings(hostile), isEmpty);
    });

    test('skips non-string wire types and recurses into nested messages', () {
      final bytes = [
        0x0a,
        5,
        ...utf8.encode('hello'),
        0x10,
        0x05,
        0x1d,
        1,
        2,
        3,
        4,
        0x21,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        0x2a,
        5,
        0x0a,
        3,
        ...utf8.encode('abc'),
      ];
      final out = protoStrings(bytes).toList();
      expect(out, containsAll(['hello', 'abc']));
    });
  });

  group('compact model formatting', () {
    test('formats bytes using the existing local-runtime display units', () {
      expect(formatCompactBytes(4 * 1024 * 1024 * 1024), '4.0 GB');
      expect(formatCompactBytes(300 * 1024 * 1024), '300 MB');
    });

    test('formats context tokens compactly', () {
      expect(formatContextTokens(32768), '32K');
      expect(formatContextTokens(512), '512');
    });
  });

  group('owner-only permission enforcement', () {
    test('async hardening bounds a stalled platform command', () async {
      final temp = File(
        '${Directory.systemTemp.path}/quotabot_permission_timeout_${pid}_test',
      )..createSync();
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync();
      });
      final stalled = Completer<ProcessResult>();
      final elapsed = Stopwatch()..start();

      await expectLater(
        enforceOwnerOnlyFileAsync(
          temp,
          timeout: const Duration(milliseconds: 20),
          run: (_, __, ___) => stalled.future,
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('checked file hardening rejects a failed platform command', () {
      final temp = File(
        '${Directory.systemTemp.path}/quotabot_permission_${pid}_test',
      )..createSync();
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync();
      });

      expect(
        () => enforceOwnerOnlyFile(
          temp,
          run: (_, __) => ProcessResult(1, 9, '', 'sensitive command output'),
          identityLookup: () => ProcessResult(
            2,
            0,
            '"User Name","SID"\n"alice","S-1-5-21-1-2-3-4"\n',
            '',
          ),
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.toString(),
            'sanitized error',
            isNot(contains('sensitive command output')),
          ),
        ),
      );
    });

    test('best-effort metadata hardening suppresses the same failure', () {
      final missing = File(
        '${Directory.systemTemp.path}/quotabot_missing_${pid}_metadata',
      );
      expect(() => restrictOwnerOnlyFile(missing), returnsNormally);
    });

    test('best-effort Windows hardening uses atomic descriptor writes', () {
      if (!Platform.isWindows) return;
      final temp = Directory.systemTemp.createTempSync(
        'quotabot_best_effort_acl_test_',
      );
      final file = File('${temp.path}/metadata')..createSync();
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final calls = <({String executable, List<String> arguments})>[];
      ProcessResult run(String executable, List<String> arguments) {
        calls.add((executable: executable, arguments: arguments));
        return ProcessResult(1, 0, '', '');
      }

      restrictOwnerOnlyFile(
        file,
        run: run,
        identityLookup: () => ProcessResult(
          2,
          0,
          '"User Name","SID"\n"alice","S-1-5-21-1-2-3-4"\n',
          '',
        ),
      );
      restrictOwnerOnlyDirectory(
        temp,
        run: run,
        identityLookup: () => ProcessResult(
          3,
          0,
          '"User Name","SID"\n"alice","S-1-5-21-1-2-3-4"\n',
          '',
        ),
      );

      expect(calls, hasLength(2));
      for (final call in calls) {
        expect(call.executable, 'powershell.exe');
        expect(call.arguments, contains('-NoProfile'));
        expect(call.arguments.last, contains('GetAccessControl'));
        expect(call.arguments.last, contains('SetAccessControl'));
        expect(call.arguments.last, contains('SetAccessRuleProtection'));
        expect(call.arguments.last, isNot(contains('icacls')));
      }
      expect(calls.first.arguments.last, contains('FileSecurity'));
      expect(calls.last.arguments.last, contains('DirectorySecurity'));
    });

    test('best-effort Windows descriptor failures remain suppressed', () {
      if (!Platform.isWindows) return;
      final temp = File(
        '${Directory.systemTemp.path}/quotabot_best_effort_failure_${pid}_test',
      )..createSync();
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync();
      });

      expect(
        () => restrictOwnerOnlyFile(
          temp,
          run: (_, __) => ProcessResult(1, 9, '', 'sensitive output'),
          identityLookup: () => ProcessResult(
            2,
            0,
            '"User Name","SID"\n"alice","S-1-5-21-1-2-3-4"\n',
            '',
          ),
        ),
        returnsNormally,
      );
    });

    test('Windows hardening removes an explicit non-owner grant', () {
      if (!Platform.isWindows) return;
      final temp = Directory.systemTemp.createTempSync('quotabot_acl_test_');
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final seeded = Process.runSync(
        'icacls',
        [temp.path, '/grant', '*S-1-1-0:(R)'],
      );
      expect(seeded.exitCode, 0);

      enforceOwnerOnlyDirectory(temp);

      final finalAcl = Process.runSync('icacls', [temp.path]);
      expect(finalAcl.exitCode, 0);
      expect(finalAcl.stdout.toString(), isNot(contains('(R)')));
      final owner = Process.runSync(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '[System.IO.Directory]::GetAccessControl('
              "'${temp.path.replaceAll("'", "''")}'"
              ').GetOwner([System.Security.Principal.SecurityIdentifier]).Value',
        ],
      );
      expect(owner.exitCode, 0);
      expect(
        owner.stdout.toString().trim(),
        windowsAclPrincipal()!.substring(1),
      );
    });

    test('Windows hardening uses one full-descriptor write', () {
      if (!Platform.isWindows) return;
      final temp = File(
        '${Directory.systemTemp.path}/quotabot_acl_command_${pid}_test',
      )..createSync();
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync();
      });
      final calls = <({String executable, List<String> arguments})>[];

      enforceOwnerOnlyFile(
        temp,
        run: (executable, arguments) {
          calls.add((executable: executable, arguments: arguments));
          return ProcessResult(1, 0, '', '');
        },
        identityLookup: () => ProcessResult(
          2,
          0,
          '"User Name","SID"\n"alice","S-1-5-21-1-2-3-4"\n',
          '',
        ),
      );

      expect(calls, hasLength(1));
      expect(calls.single.executable, 'powershell.exe');
      expect(calls.single.arguments, contains('-NoProfile'));
      expect(calls.single.arguments.last, contains('GetAccessControl'));
      expect(calls.single.arguments.last, contains('SetAccessControl'));
      expect(calls.single.arguments.last, contains('SetAccessRuleProtection'));
    });

    test('macOS hardening removes an explicit non-owner ACL', () {
      if (!Platform.isMacOS) return;
      final temp = File(
        '${Directory.systemTemp.path}/quotabot_acl_${pid}_test',
      )..createSync();
      final directory =
          Directory.systemTemp.createTempSync('quotabot_acl_dir_test_');
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final seeded = Process.runSync(
        '/bin/chmod',
        ['+a', 'everyone allow read', temp.path],
      );
      expect(seeded.exitCode, 0);
      final seededDirectory = Process.runSync(
        '/bin/chmod',
        ['+a', 'everyone allow list,search', directory.path],
      );
      expect(seededDirectory.exitCode, 0);
      final initialFileAcl = Process.runSync('/bin/ls', ['-le', temp.path]);
      final initialDirectoryAcl =
          Process.runSync('/bin/ls', ['-lde', directory.path]);
      expect(initialFileAcl.exitCode, 0);
      expect(initialDirectoryAcl.exitCode, 0);
      expect(
        initialFileAcl.stdout.toString().toLowerCase(),
        contains('everyone allow read'),
      );
      expect(
        initialDirectoryAcl.stdout.toString().toLowerCase(),
        contains('everyone allow list,search'),
      );

      enforceOwnerOnlyFile(temp);
      enforceOwnerOnlyDirectory(directory);

      final finalFileAcl = Process.runSync('/bin/ls', ['-le', temp.path]);
      final finalDirectoryAcl =
          Process.runSync('/bin/ls', ['-lde', directory.path]);
      expect(finalFileAcl.exitCode, 0);
      expect(finalDirectoryAcl.exitCode, 0);
      expect(
        finalFileAcl.stdout.toString().toLowerCase(),
        isNot(contains('allow read')),
      );
      expect(
        finalDirectoryAcl.stdout.toString().toLowerCase(),
        isNot(contains('allow list,search')),
      );
    });
  });

  group('Windows ACL identity parsing', () {
    test('extracts an SID from whoami csv output', () {
      expect(
        parseWhoamiUserSid(
          '"User Name","SID"\r\n'
          '"DESKTOP\\alice","S-1-5-21-100-200-300-1001"\r\n',
        ),
        '*S-1-5-21-100-200-300-1001',
      );
    });

    test('ignores malformed or non-user output', () {
      expect(parseWhoamiUserSid('USERDOMAIN\\Everyone'), isNull);
      expect(
          parseWhoamiUserSid('"User Name","SID"\n"bob","not-a-sid"'), isNull);
    });

    test('handles escaped csv quotes before the SID column', () {
      expect(
        parseWhoamiUserSid(
          '"User ""Display"" Name","SID"\n'
          '"DESKTOP\\alice","S-1-5-21-100-200-300-1001"\n',
        ),
        '*S-1-5-21-100-200-300-1001',
      );
    });

    test('windowsAclPrincipal uses command output instead of environment text',
        () {
      final principal = windowsAclPrincipal(
        lookup: () => ProcessResult(
          7,
          0,
          '"User Name","SID"\n"IGNORED\\Bob","S-1-5-21-1-2-3-4"\n',
          '',
        ),
      );
      expect(principal, '*S-1-5-21-1-2-3-4');
    });

    test('windowsAclPrincipal fails closed when whoami fails', () {
      final principal = windowsAclPrincipal(
        lookup: () => ProcessResult(7, 1, '', 'no identity'),
      );
      expect(principal, isNull);
    });
  });

  group('agentic tool detection', () {
    test('detects supported tool directories through injected paths', () {
      final seen = <String>{
        r'C:\home\.kiro',
        r'C:\appdata\Cursor',
        r'C:\home\.codeium\windsurf',
        r'C:\xdg\antigravity',
      };

      expect(
        detectInstalledAgenticTools(
          homePath: r'C:\home',
          appDataPath: r'C:\appdata',
          xdgDataPath: r'C:\xdg',
          exists: (path) => seen.contains(path.replaceAll('/', r'\')),
        ),
        {'antigravity', 'cursor', 'kiro', 'windsurf'},
      );
    });

    test('returns empty when no supported directories exist', () {
      expect(
        detectInstalledAgenticTools(
          homePath: r'C:\home',
          appDataPath: r'C:\appdata',
          xdgDataPath: r'C:\xdg',
          exists: (_) => false,
        ),
        isEmpty,
      );
    });
  });
}
