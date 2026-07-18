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

  test('live probe fails soft and returns internally consistent evidence',
      () async {
    final hardware = await readLocalHardware(refresh: true);
    expect(
      hardware,
      isNotNull,
      reason: 'supported desktop operating systems expose system memory',
    );
    final evidence = hardware!;

    expect(evidence.hasMemoryEvidence, isTrue);
    expect(evidence.asOf, greaterThan(0));
    final systemTotal = evidence.systemMemoryTotalBytes;
    final systemAvailable = evidence.systemMemoryAvailableBytes;
    if (systemTotal != null && systemAvailable != null) {
      expect(systemAvailable, lessThanOrEqualTo(systemTotal));
    }
    final gpuTotal = evidence.gpuMemoryTotalBytes;
    final gpuAvailable = evidence.gpuMemoryAvailableBytes;
    if (gpuTotal != null && gpuAvailable != null) {
      expect(gpuAvailable, lessThanOrEqualTo(gpuTotal));
    }
  });
}
