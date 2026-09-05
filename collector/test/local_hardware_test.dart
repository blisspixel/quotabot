import 'package:quotabot_collector/local_hardware.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/registry.dart';
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

    test('parses NVIDIA GPU names from the three-column query', () {
      final sample = parseNvidiaSmiMemory(
        'NVIDIA GeForce RTX 4090, 24576, 18000\n',
      );
      expect(sample?.name, 'NVIDIA GeForce RTX 4090');
      expect(sample?.totalBytes, 24576 * 1024 * 1024);
      expect(sample?.availableBytes, 18000 * 1024 * 1024);
      expect(sample?.utilizationPercent, isNull);
    });

    test('parses host GPU utilization from the current NVIDIA query', () {
      final sample = parseNvidiaSmiMemory(
        'NVIDIA GeForce RTX 4090, 24576, 18000, 37\n',
      );
      expect(sample?.name, 'NVIDIA GeForce RTX 4090');
      expect(sample?.totalBytes, 24576 * 1024 * 1024);
      expect(sample?.availableBytes, 18000 * 1024 * 1024);
      expect(sample?.utilizationPercent, 37);
      expect(
        parseNvidiaSmiMemory('NVIDIA GPU, 24576, 18000, 101'),
        isNull,
      );
    });

    test('preserves the selected NVIDIA GPU memory and activity together', () {
      final sample = parseNvidiaSmiMemory(
        'NVIDIA GeForce RTX 4070, 12288, 11000, 98\n'
        'NVIDIA GeForce RTX 4090, 24576, 18000, 12\n',
      );

      expect(sample?.name, 'NVIDIA GeForce RTX 4090');
      expect(sample?.totalBytes, 24 * _gib);
      expect(sample?.availableBytes, 18000 * 1024 * 1024);
      expect(sample?.utilizationPercent, 12);
      expect(sample?.count, 2);
    });

    test('unknown NVIDIA activity preserves direct memory evidence', () {
      final sample = parseNvidiaSmiMemory(
        'NVIDIA GeForce RTX 4090, 24576, 18000, [N/A]\n',
      );

      expect(sample?.totalBytes, 24 * _gib);
      expect(sample?.availableBytes, 18000 * 1024 * 1024);
      expect(sample?.utilizationPercent, isNull);
    });

    test('Windows GPU metadata reads identity without ambiguous metrics',
        () async {
      var commandCount = 0;
      final sample = await readWindowsGpuMetadata('powershell.exe', (
        executable,
        arguments,
      ) async {
        commandCount++;
        expect(executable, 'powershell.exe');
        expect(arguments.take(4), [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
        ]);
        expect(arguments.last, contains('-Property Name -ErrorAction Stop'));
        expect(arguments.last, isNot(contains('AdapterRAM')));
        expect(arguments.last, isNot(contains('Get-Counter')));
        return 'AMD Radeon(TM) 780M\t\r\n';
      });

      expect(commandCount, 1);
      expect(sample?.name, 'AMD Radeon 780M');
      expect(sample?.count, 1);
      expect(sample?.totalBytes, isNull);
      expect(sample?.availableBytes, isNull);
      expect(sample?.utilizationPercent, isNull);
    });

    test('Windows GPU metadata unavailable or malformed output fails soft',
        () async {
      for (final output in <String?>[
        null,
        '',
        'invalid',
        '__utilization__\t42'
      ]) {
        expect(
          await readWindowsGpuMetadata(
            'powershell.exe',
            (_, __) async => output,
          ),
          isNull,
        );
      }
      expect(
        await readWindowsGpuMetadata('powershell.exe', (_, __) async {
          throw StateError('CIM unavailable');
        }),
        isNull,
      );
    });

    test('Windows fallback preserves GPU identity and no numeric evidence', () {
      final sample = parseWindowsGpuInfo(
        'Microsoft Basic Display Adapter\t4294967295\n'
        'AMD Radeon(TM) 780M\t\n'
        '__utilization__\t6\n',
      );
      expect(sample?.name, 'AMD Radeon 780M');
      expect(sample?.totalBytes, isNull);
      expect(sample?.availableBytes, isNull);
      expect(sample?.utilizationPercent, isNull);
      expect(sample?.count, 1);
      expect(parseWindowsGpuInfo('Basic Display Adapter\t0'), isNull);
    });

    test('Windows CIM capacities never become authoritative GPU bytes', () {
      for (final reportedBytes in [
        '',
        '0',
        '2147483648',
        '4294967295',
        '4294967296',
        '${24 * _gib}',
        '-1',
        '18446744073709551615',
        'unknown',
      ]) {
        final sample = parseWindowsGpuInfo('AMD Radeon\t$reportedBytes\n');

        expect(sample?.name, 'AMD Radeon', reason: reportedBytes);
        expect(sample?.count, 1, reason: reportedBytes);
        expect(sample?.totalBytes, isNull, reason: reportedBytes);
        expect(sample?.availableBytes, isNull, reason: reportedBytes);
        expect(sample?.utilizationPercent, isNull, reason: reportedBytes);
      }
    });

    test('Windows aggregate counters never describe a selected GPU', () {
      const rows = [
        'Intel(R) Arc(TM) Graphics\t4294967295',
        'AMD Radeon\t2147483648',
      ];
      for (final orderedRows in [rows, rows.reversed]) {
        for (final counter in [
          '0',
          '6',
          '100',
          '101',
          '-1',
          'NaN',
          'unknown'
        ]) {
          final sample = parseWindowsGpuInfo(
            '${orderedRows.join('\n')}\n__utilization__\t$counter\n',
          );

          expect(sample?.name, 'AMD Radeon');
          expect(sample?.count, 2);
          expect(sample?.totalBytes, isNull);
          expect(sample?.availableBytes, isNull);
          expect(sample?.utilizationPercent, isNull, reason: counter);
        }
      }
    });

    test('name-only Windows evidence stays unknown for model fit and JSON', () {
      final sample = parseWindowsGpuInfo('AMD Radeon\t4294967295\n')!;
      final hardware = LocalHardwareInfo(
        asOf: 123,
        gpuName: sample.name,
        gpuCount: sample.count,
        gpuMemoryTotalBytes: sample.totalBytes,
        gpuMemoryAvailableBytes: sample.availableBytes,
        gpuUtilizationPercent: sample.utilizationPercent,
      );
      final fit = localModelHardwareFit(
        const ModelInfo(
          id: 'local-model',
          displayName: 'Local model',
          sizeBytes: 8 * _gib,
        ),
        hardware,
      );

      expect(fit.status, LocalHardwareFitStatus.unknown);
      expect(fit.basis, 'insufficient_evidence');
      expect(
        LocalHardwareInfo.fromJson(hardware.toJson()).toJson(),
        {'as_of': 123, 'gpu_name': 'AMD Radeon', 'gpu_count': 1},
      );
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

    expect(evidence.hasMemoryEvidence || evidence.gpuName != null, isTrue);
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
    final gpuUtilization = evidence.gpuUtilizationPercent;
    if (gpuUtilization != null) {
      expect(gpuUtilization, inInclusiveRange(0, 100));
    }
  });
}
