/// Passive, bounded local memory discovery for hardware-fit guidance.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

const _kib = 1024;
const _mib = 1024 * 1024;
const _maxMemoryBytes = 16 * 1024 * 1024 * 1024 * 1024 * 1024;
const _maxCommandOutputBytes = 64 * 1024;
const _commandDeadline = Duration(seconds: 4);
const _cacheDuration = Duration(seconds: 30);

typedef MemoryPoolSample = ({int totalBytes, int? availableBytes});
typedef GpuMemorySample = ({
  int totalBytes,
  int availableBytes,
  int count,
});
typedef HardwareMetadataCommand = Future<String?> Function(
  String executable,
  List<String> arguments,
);

LocalHardwareInfo? _cachedHardware;
DateTime? _lastProbeAt;
Future<LocalHardwareInfo?>? _inFlightProbe;

/// Reads passive system and GPU memory metadata, with a short process-local
/// cache so a desktop refresh loop does not repeatedly invoke operating-system
/// tools. No model is loaded and no inference or throughput probe is performed.
Future<LocalHardwareInfo?> readLocalHardware({bool refresh = false}) {
  final now = DateTime.now();
  final last = _lastProbeAt;
  if (!refresh && last != null && now.difference(last) < _cacheDuration) {
    return Future.value(_cachedHardware);
  }
  final current = _inFlightProbe;
  if (current != null) return current;
  final probe = _readLocalHardwareUncached(now);
  _inFlightProbe = probe;
  return probe.whenComplete(() {
    if (identical(_inFlightProbe, probe)) _inFlightProbe = null;
  });
}

Future<LocalHardwareInfo?> _readLocalHardwareUncached(DateTime captured) async {
  final systemFuture = _readSystemMemory();
  final gpuFuture = _readGpuMemory();
  final system = await systemFuture;
  final gpu = await gpuFuture;
  final result = system == null && gpu == null
      ? null
      : LocalHardwareInfo(
          asOf: captured.millisecondsSinceEpoch ~/ 1000,
          systemMemoryTotalBytes: system?.totalBytes,
          systemMemoryAvailableBytes: system?.availableBytes,
          gpuMemoryTotalBytes: gpu?.totalBytes,
          gpuMemoryAvailableBytes: gpu?.availableBytes,
          gpuCount: gpu?.count ?? 0,
        );
  _lastProbeAt = captured;
  _cachedHardware = result;
  return result;
}

Future<MemoryPoolSample?> _readSystemMemory() async {
  switch (Platform.operatingSystem) {
    case 'linux':
      try {
        final file = File('/proc/meminfo');
        if (!file.existsSync() || file.lengthSync() > _maxCommandOutputBytes) {
          return null;
        }
        return parseLinuxMemoryInfo(await file.readAsString());
      } catch (_) {
        return null;
      }
    case 'windows':
      final root = Platform.environment['SystemRoot'];
      if (root == null || root.isEmpty) return null;
      final executable =
          '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
      if (!File(executable).existsSync()) return null;
      return readWindowsMemoryMetadata(executable, _runBounded);
    case 'macos':
      final totalFuture = _runBounded(
        '/usr/sbin/sysctl',
        const ['-n', 'hw.memsize'],
      );
      final vmFuture = _runBounded('/usr/bin/vm_stat', const []);
      final total = await totalFuture;
      final vm = await vmFuture;
      return total == null ? null : parseMacMemoryInfo(total, vm);
    default:
      return null;
  }
}

/// Reads bounded Windows physical-memory metadata without localizing labels.
///
/// The direct operating-system API avoids a WMI dependency on the normal path.
/// CIM remains a compatibility fallback for hosts where the built-in
/// Microsoft.VisualBasic assembly is unavailable or restricted. Both paths run
/// inside one process so the complete probe retains one bounded deadline.
Future<MemoryPoolSample?> readWindowsMemoryMetadata(
  String executable,
  HardwareMetadataCommand run,
) async {
  const command = r'$ErrorActionPreference="Stop"; '
      r'try { '
      r'Add-Type -AssemblyName Microsoft.VisualBasic; '
      r'$c=[Microsoft.VisualBasic.Devices.ComputerInfo]::new(); '
      r'$total=[uint64]($c.TotalPhysicalMemory -shr 10); '
      r'$free=[uint64]($c.AvailablePhysicalMemory -shr 10); '
      r'if ($total -eq 0 -or $free -gt $total) { throw "invalid direct memory metadata" } '
      r'} catch { '
      r'$o=Get-CimInstance -ClassName Win32_OperatingSystem '
      r'-Property TotalVisibleMemorySize,FreePhysicalMemory '
      r'-ErrorAction Stop; '
      r'if ($null -eq $o.TotalVisibleMemorySize -or $null -eq $o.FreePhysicalMemory) { throw "missing CIM memory metadata" }; '
      r'$total=[uint64]$o.TotalVisibleMemorySize; '
      r'$free=[uint64]$o.FreePhysicalMemory '
      r'}; '
      r'if ($total -eq 0 -or $free -gt $total) { throw "invalid memory metadata" }; '
      r'$culture=[Globalization.CultureInfo]::InvariantCulture; '
      r'[Console]::Out.Write([string]::Concat('
      r'$total.ToString($culture),",",$free.ToString($culture)))';
  try {
    final output = await run(executable, const [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      command,
    ]);
    return output == null ? null : parseWindowsMemoryInfo(output);
  } catch (_) {
    return null;
  }
}

Future<GpuMemorySample?> _readGpuMemory() async {
  final executable = _nvidiaSmiPath();
  if (executable == null) return null;
  final output = await _runBounded(executable, const [
    '--query-gpu=memory.total,memory.free',
    '--format=csv,noheader,nounits',
  ]);
  return output == null ? null : parseNvidiaSmiMemory(output);
}

String? _nvidiaSmiPath() {
  final candidates = switch (Platform.operatingSystem) {
    'windows' => [
        if ((Platform.environment['SystemRoot'] ?? '').isNotEmpty)
          '${Platform.environment['SystemRoot']}\\System32\\nvidia-smi.exe',
        if ((Platform.environment['ProgramFiles'] ?? '').isNotEmpty)
          '${Platform.environment['ProgramFiles']}\\NVIDIA Corporation\\NVSMI\\nvidia-smi.exe',
      ],
    'linux' => const ['/usr/bin/nvidia-smi'],
    _ => const <String>[],
  };
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// Parses Linux `/proc/meminfo`. `MemAvailable` is preferred because it includes
/// reclaimable cache; a missing value leaves current availability unknown.
MemoryPoolSample? parseLinuxMemoryInfo(String input) {
  int? kibValue(String label) {
    final match = RegExp(
      '^${RegExp.escape(label)}:\\s+(\\d+)\\s+kB\\s*\$',
      multiLine: true,
    ).firstMatch(input);
    return _scaledBytes(match?.group(1), _kib, allowZero: label != 'MemTotal');
  }

  final total = kibValue('MemTotal');
  if (total == null) return null;
  final available = kibValue('MemAvailable');
  return (
    totalBytes: total,
    availableBytes: available != null && available <= total ? available : null,
  );
}

/// Parses a bounded normalized Windows memory response. Both the ComputerInfo
/// and CIM command paths emit integer KiB before reaching this parser.
MemoryPoolSample? parseWindowsMemoryInfo(String input) {
  final parts = input.trim().split(',');
  if (parts.length != 2) return null;
  final total = _scaledBytes(parts[0], _kib);
  final available = _scaledBytes(parts[1], _kib, allowZero: true);
  if (total == null) return null;
  return (
    totalBytes: total,
    availableBytes: available != null && available <= total ? available : null,
  );
}

/// Parses macOS `sysctl hw.memsize` and `vm_stat`. Available memory is the
/// conservative sum of free, inactive, and speculative pages.
MemoryPoolSample? parseMacMemoryInfo(String totalOutput, String? vmOutput) {
  final total = _scaledBytes(totalOutput.trim(), 1);
  if (total == null) return null;
  final vm = vmOutput;
  if (vm == null) return (totalBytes: total, availableBytes: null);
  final pageSizeMatch =
      RegExp(r'page size of (\d+) bytes').firstMatch(vm)?.group(1);
  final pageSize = int.tryParse(pageSizeMatch ?? '');
  if (pageSize == null || pageSize <= 0 || pageSize > _mib) {
    return (totalBytes: total, availableBytes: null);
  }
  var pages = 0;
  var sawPages = false;
  for (final label in ['Pages free', 'Pages inactive', 'Pages speculative']) {
    final match = RegExp(
      '^${RegExp.escape(label)}:\\s+(\\d+)\\.\\s*\$',
      multiLine: true,
    ).firstMatch(vm);
    final value = int.tryParse(match?.group(1) ?? '');
    if (value != null && value >= 0) {
      pages += value;
      sawPages = true;
    }
  }
  final available = sawPages ? _safeProduct(pages, pageSize) : null;
  return (
    totalBytes: total,
    availableBytes: available != null && available <= total ? available : null,
  );
}

/// Parses one `total MiB, free MiB` row per NVIDIA GPU and returns the largest
/// single device. Separate GPU pools are deliberately never summed.
GpuMemorySample? parseNvidiaSmiMemory(String input) {
  final pools = <({int total, int available})>[];
  for (final line in input.split(RegExp(r'[\r\n]+'))) {
    if (line.trim().isEmpty) continue;
    final parts = line.split(',');
    if (parts.length != 2) continue;
    final total = _scaledBytes(parts[0], _mib);
    final available = _scaledBytes(parts[1], _mib, allowZero: true);
    if (total == null || available == null || available > total) continue;
    pools.add((total: total, available: available));
  }
  if (pools.isEmpty) return null;
  pools.sort((a, b) {
    final total = b.total.compareTo(a.total);
    return total != 0 ? total : b.available.compareTo(a.available);
  });
  final largest = pools.first;
  return (
    totalBytes: largest.total,
    availableBytes: largest.available,
    count: pools.length,
  );
}

int? _scaledBytes(String? input, int multiplier, {bool allowZero = false}) {
  final value = int.tryParse(input?.trim() ?? '');
  if (value == null || value < (allowZero ? 0 : 1)) return null;
  return _safeProduct(value, multiplier);
}

int? _safeProduct(int value, int multiplier) {
  if (value < 0 || multiplier <= 0 || value > _maxMemoryBytes ~/ multiplier) {
    return null;
  }
  return value * multiplier;
}

Future<String?> _runBounded(
  String executable,
  List<String> arguments,
) async {
  Process process;
  try {
    process = await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.normal,
    );
  } catch (_) {
    return null;
  }

  final output = <int>[];
  var overflow = false;
  final stdoutDone = process.stdout.listen((chunk) {
    final remaining = _maxCommandOutputBytes - output.length;
    if (remaining <= 0) {
      overflow = true;
      return;
    }
    if (chunk.length > remaining) {
      output.addAll(chunk.take(remaining));
      overflow = true;
    } else {
      output.addAll(chunk);
    }
  }).asFuture<void>();
  final stderrDone = process.stderr.drain<void>();

  int exit;
  try {
    exit = await process.exitCode.timeout(_commandDeadline);
  } on TimeoutException {
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 1));
    } catch (_) {
      // Best effort only. Stream listeners still drain bounded output.
    }
    await _finishProcessStreams(stdoutDone, stderrDone);
    return null;
  } catch (_) {
    process.kill();
    await _finishProcessStreams(stdoutDone, stderrDone);
    return null;
  }
  await _finishProcessStreams(stdoutDone, stderrDone);
  if (exit != 0 || overflow) return null;
  return utf8.decode(output, allowMalformed: true);
}

Future<void> _finishProcessStreams(
  Future<void> stdoutDone,
  Future<void> stderrDone,
) async {
  try {
    await Future.wait<void>([stdoutDone, stderrDone])
        .timeout(const Duration(seconds: 1));
  } catch (_) {
    // Process output is advisory and already bounded. A pipe that fails to
    // close after process exit must not hold the collection loop open.
  }
}
