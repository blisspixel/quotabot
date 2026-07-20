import 'package:quotabot_collector/local_hardware.dart';
import 'package:test/test.dart';

const _gib = 1024 * 1024 * 1024;

void main() {
  group('local hardware parsers', () {
    test('parses Linux total and available memory', () {
      final sample = parseLinuxMemoryInfo('''
MemTotal:       16384000 kB
MemFree:         1024000 kB
MemAvailable:   12288000 kB
Buffers:          100000 kB
''');

      expect(sample?.totalBytes, 16384000 * 1024);
      expect(sample?.availableBytes, 12288000 * 1024);
    });

    test('keeps Linux availability unknown when it exceeds total', () {
      final sample = parseLinuxMemoryInfo('''
MemTotal:       1000 kB
MemAvailable:   2000 kB
''');

      expect(sample?.totalBytes, 1000 * 1024);
      expect(sample?.availableBytes, isNull);
      expect(parseLinuxMemoryInfo('MemFree: 100 kB'), isNull);
    });

    test('parses bounded Windows KiB output', () {
      final sample = parseWindowsMemoryInfo('16777216,8388608');

      expect(sample?.totalBytes, 16 * _gib);
      expect(sample?.availableBytes, 8 * _gib);
      expect(parseWindowsMemoryInfo('broken'), isNull);
      expect(parseWindowsMemoryInfo('100,200')?.availableBytes, isNull);
    });

    test('Windows metadata keeps both APIs inside one bounded process',
        () async {
      final commands = <String>[];
      final sample = await readWindowsMemoryMetadata('powershell.exe', (
        executable,
        arguments,
      ) async {
        expect(executable, 'powershell.exe');
        commands.add(arguments.last);
        return '16777216,8388608';
      });

      expect(sample?.totalBytes, 16 * _gib);
      expect(sample?.availableBytes, 8 * _gib);
      expect(commands, hasLength(1));
      final command = commands.single;
      expect(command, contains('ComputerInfo'));
      expect(command, contains('Get-CimInstance'));
      expect(command, contains('[uint64]'));
      expect(command, contains('-shr 10'));
      expect(command, contains('InvariantCulture'));
      expect(command, contains(r'$null -eq $o.TotalVisibleMemorySize'));
      expect(command, contains(r'$null -eq $o.FreePhysicalMemory'));
      expect(
        command.indexOf('invalid direct memory metadata'),
        lessThan(command.indexOf('} catch {')),
      );
    });

    test('Windows metadata command failures and invalid output fail soft',
        () async {
      expect(
        await readWindowsMemoryMetadata(
            'powershell.exe', (_, __) async => null),
        isNull,
      );
      expect(
        await readWindowsMemoryMetadata(
            'powershell.exe', (_, __) async => 'invalid'),
        isNull,
      );
      expect(
        await readWindowsMemoryMetadata('powershell.exe', (_, __) async {
          throw StateError('blocked by host policy');
        }),
        isNull,
      );
    });

    test('parses macOS total and reclaimable pages', () {
      final sample = parseMacMemoryInfo('17179869184\n', '''
Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                               100000.
Pages active:                            200000.
Pages inactive:                          300000.
Pages speculative:                        50000.
''');

      expect(sample?.totalBytes, 16 * _gib);
      expect(sample?.availableBytes, 450000 * 4096);
      expect(
        parseMacMemoryInfo('17179869184', 'bad')?.availableBytes,
        isNull,
      );
    });

    test('selects the largest single NVIDIA GPU without summing devices', () {
      final sample = parseNvidiaSmiMemory('''
8192, 7000
24576, 18000
12288, 11000
''');

      expect(sample?.totalBytes, 24576 * 1024 * 1024);
      expect(sample?.availableBytes, 18000 * 1024 * 1024);
      expect(sample?.count, 3);
      expect(parseNvidiaSmiMemory('bad\n100,200'), isNull);
    });

    test('rejects zero, negative, and implausibly large values', () {
      expect(parseWindowsMemoryInfo('0,0'), isNull);
      expect(parseWindowsMemoryInfo('-1,0'), isNull);
      expect(
        parseWindowsMemoryInfo('999999999999999999999999999999,1'),
        isNull,
      );
      expect(parseNvidiaSmiMemory('0,0'), isNull);
    });
  });

  test('live probe never throws and returned evidence is internally consistent',
      () async {
    final hardware = await readLocalHardware(refresh: true);
    if (hardware == null) return;
    final evidence = hardware;

    expect(evidence.hasMemoryEvidence, isTrue);
    expect(evidence.asOf, greaterThan(0));
    final systemTotal = evidence.systemMemoryTotalBytes;
    final systemAvailable = evidence.systemMemoryAvailableBytes;
    if (systemTotal != null) {
      expect(systemTotal, greaterThan(0));
    }
    if (systemAvailable != null) {
      expect(systemAvailable, greaterThanOrEqualTo(0));
    }
    if (systemTotal != null && systemAvailable != null) {
      expect(systemAvailable, lessThanOrEqualTo(systemTotal));
    }
    final gpuTotal = evidence.gpuMemoryTotalBytes;
    final gpuAvailable = evidence.gpuMemoryAvailableBytes;
    if (gpuTotal != null) {
      expect(gpuTotal, greaterThan(0));
      expect(evidence.gpuCount, greaterThan(0));
    }
    if (gpuAvailable != null) {
      expect(gpuAvailable, greaterThanOrEqualTo(0));
    }
    if (gpuTotal != null && gpuAvailable != null) {
      expect(gpuAvailable, lessThanOrEqualTo(gpuTotal));
    }
  });
}
