import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'profiles.dart';
import 'util.dart';

const manualQuotaSchema = 'quotabot.manual.v1';
const manualQuotaSource = providerQuotaManualSource;

class ManualQuotaEntry {
  final String provider;
  final String displayName;
  final String account;
  final String? plan;
  final String window;
  final double used;
  final double limit;
  final int resetsAt;
  final int updatedAt;

  const ManualQuotaEntry({
    required this.provider,
    required this.displayName,
    required this.account,
    required this.window,
    required this.used,
    required this.limit,
    required this.resetsAt,
    required this.updatedAt,
    this.plan,
  });

  ProviderQuota toQuota() => ProviderQuota(
        provider: provider,
        displayName: displayName,
        account: account,
        plan: plan,
        source: manualQuotaSource,
        asOf: updatedAt,
        details: const ['Self-reported manual quota'],
        windows: [
          QuotaWindow(
            label: window,
            used: used,
            limit: limit,
            resetsAt: resetsAt,
          ),
        ],
      );

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'display_name': displayName,
        'account': account,
        if (plan != null) 'plan': plan,
        'window': window,
        'used': used,
        'limit': limit,
        'resets_at': resetsAt,
        'updated_at': updatedAt,
      };

  factory ManualQuotaEntry.fromJson(Map<String, dynamic> json) {
    final provider = normalizeProviderId(json['provider']?.toString());
    final displayName = _text(json['display_name']) ?? provider;
    final account = _text(json['account']) ?? 'default';
    final window = _text(json['window']) ?? 'manual';
    final used = _finite(json['used']);
    final limit = _finite(json['limit']);
    final resetsAt = _int(json['resets_at']);
    final updatedAt = _int(json['updated_at']) ?? nowEpoch();
    if (provider == null ||
        displayName == null ||
        used == null ||
        limit == null ||
        resetsAt == null ||
        limit <= 0 ||
        used < 0) {
      throw const FormatException('invalid manual quota');
    }
    return ManualQuotaEntry(
      provider: provider,
      displayName: displayName,
      account: account,
      plan: _text(json['plan']),
      window: window,
      used: used.clamp(0.0, limit).toDouble(),
      limit: limit,
      resetsAt: resetsAt,
      updatedAt: updatedAt,
    );
  }
}

Directory manualQuotaDir({Directory? root}) {
  final dir = root ?? quotabotDir('manual');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  restrictOwnerOnlyDirectory(dir);
  return dir;
}

File manualQuotaFile({Directory? dir}) => File(
      '${manualQuotaDir(root: dir).path}/quotas.json',
    );

List<ManualQuotaEntry> loadManualQuotaEntries({Directory? dir}) {
  try {
    final file = manualQuotaFile(dir: dir);
    if (!file.existsSync() || file.lengthSync() > _maxManualQuotaBytes) {
      return const [];
    }
    final decoded = jsonDecode(file.readAsStringSync());
    final entries = decoded is Map ? decoded['entries'] : null;
    if (entries is! List) return const [];
    return [
      for (final entry in entries)
        if (entry is Map)
          tryParseManualQuotaEntry(entry.cast<String, dynamic>())
        else
          null,
    ].nonNulls.toList()
      ..sort(_compareEntries);
  } catch (_) {
    return const [];
  }
}

List<ProviderQuota> loadManualProviderQuotas({Directory? dir}) =>
    loadManualQuotaEntries(dir: dir).map((entry) => entry.toQuota()).toList();

ManualQuotaEntry? tryParseManualQuotaEntry(Map<String, dynamic> json) {
  try {
    return ManualQuotaEntry.fromJson(json);
  } catch (_) {
    return null;
  }
}

void saveManualQuotaEntries(
  Iterable<ManualQuotaEntry> entries, {
  Directory? dir,
}) {
  final normalized = <String, ManualQuotaEntry>{};
  for (final entry in entries) {
    normalized[_key(entry.provider, entry.account)] = entry;
  }
  final out = normalized.values.toList()..sort(_compareEntries);
  final file = manualQuotaFile(dir: dir);
  final tmp = File('${file.path}.$pid.tmp');
  tmp.writeAsStringSync(jsonEncode({
    'schema': manualQuotaSchema,
    'entries': out.map((entry) => entry.toJson()).toList(),
  }));
  restrictOwnerOnlyFile(tmp);
  tmp.renameSync(file.path);
  restrictOwnerOnlyFile(file);
}

ManualQuotaEntry setManualQuotaEntry(
  ManualQuotaEntry entry, {
  Directory? dir,
}) {
  final entries = loadManualQuotaEntries(dir: dir)
      .where((existing) =>
          _key(existing.provider, existing.account) !=
          _key(entry.provider, entry.account))
      .toList()
    ..add(entry);
  saveManualQuotaEntries(entries, dir: dir);
  return entry;
}

bool removeManualQuotaEntry(
  String provider, {
  String account = 'default',
  Directory? dir,
}) {
  final normalized = normalizeProviderId(provider);
  if (normalized == null) return false;
  final target = _key(normalized, account);
  final entries = loadManualQuotaEntries(dir: dir);
  final kept = [
    for (final entry in entries)
      if (_key(entry.provider, entry.account) != target) entry,
  ];
  if (kept.length == entries.length) return false;
  saveManualQuotaEntries(kept, dir: dir);
  return true;
}

int? parseManualReset(String? value) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return null;
  final epoch = int.tryParse(raw);
  if (epoch != null && epoch >= 0) return epoch;
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return null;
  return parsed.toUtc().millisecondsSinceEpoch ~/ 1000;
}

ManualQuotaEntry? buildManualQuotaEntry({
  required String? provider,
  required String? displayName,
  required String? account,
  required String? plan,
  required String? window,
  required String? used,
  required String? limit,
  required String? reset,
  required int now,
}) {
  final normalizedProvider = normalizeProviderId(provider);
  final parsedUsed = _finite(used);
  final parsedLimit = _finite(limit);
  final parsedReset = parseManualReset(reset);
  if (normalizedProvider == null ||
      parsedUsed == null ||
      parsedLimit == null ||
      parsedLimit <= 0 ||
      parsedUsed < 0 ||
      parsedReset == null) {
    return null;
  }
  final cleanDisplayName =
      displayName == null ? normalizedProvider : _text(displayName);
  final cleanAccount = account == null ? 'default' : _text(account);
  final cleanWindow = window == null ? 'manual' : _text(window);
  final cleanPlan = plan == null ? null : _text(plan);
  if (cleanDisplayName == null ||
      cleanAccount == null ||
      cleanWindow == null ||
      (plan != null && cleanPlan == null)) {
    return null;
  }
  return ManualQuotaEntry(
    provider: normalizedProvider,
    displayName: cleanDisplayName,
    account: cleanAccount,
    plan: cleanPlan,
    window: cleanWindow,
    used: parsedUsed.clamp(0.0, parsedLimit).toDouble(),
    limit: parsedLimit,
    resetsAt: parsedReset,
    updatedAt: now,
  );
}

const _maxManualQuotaBytes = 256 * 1024;

String _key(String provider, String account) => '$provider\x00$account';

int _compareEntries(ManualQuotaEntry a, ManualQuotaEntry b) {
  final provider = a.provider.compareTo(b.provider);
  if (provider != 0) return provider;
  return a.account.compareTo(b.account);
}

String? _text(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty || text.length > 128) return null;
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) return null;
  return text;
}

double? _finite(Object? value) {
  final parsed = switch (value) {
    num n => n.toDouble(),
    String s => double.tryParse(s.trim()),
    _ => null,
  };
  return parsed != null && parsed.isFinite ? parsed : null;
}

int? _int(Object? value) {
  final parsed = switch (value) {
    int n => n,
    num n => n.toInt(),
    String s => int.tryParse(s.trim()),
    _ => null,
  };
  return parsed != null && parsed >= 0 ? parsed : null;
}
