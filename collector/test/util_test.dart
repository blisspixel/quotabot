import 'dart:convert';
import 'dart:io';

import 'package:quotabot_collector/util.dart';
import 'package:test/test.dart';

void main() {
  test('nowEpoch and home return sensible values', () {
    expect(nowEpoch(), greaterThan(1700000000));
    expect(home(), isNotEmpty);
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
