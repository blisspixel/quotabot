import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'util.dart';

const defaultLeaseSeconds = 120;
const minLeaseSeconds = 15;
const maxLeaseSeconds = 3600;
const defaultLeaseWeightPercent = 15.0;
const minLeaseWeightPercent = 1.0;
const maxLeaseWeightPercent = 50.0;
const maxActiveLeases = 256;

typedef LeaseIdFactory = String Function();

Directory leaseDir() => quotabotDir('leases');

String _normalizeIdPart(String value) =>
    value.trim().replaceAll(RegExp(r'[^a-zA-Z0-9._@-]'), '_');

String normalizeLeaseProvider(String value) {
  final normalized = _normalizeIdPart(value).toLowerCase();
  return normalized.isEmpty ? 'unknown' : normalized;
}

String normalizeLeaseAccount(String? value) {
  final normalized = _normalizeIdPart(value ?? '');
  return normalized.isEmpty ? 'default' : normalized;
}

int normalizeLeaseSeconds(Object? value) {
  final seconds = value is num ? value.round() : defaultLeaseSeconds;
  return seconds.clamp(minLeaseSeconds, maxLeaseSeconds).toInt();
}

double normalizeLeaseWeight(Object? value) {
  final weight = value is num ? value.toDouble() : defaultLeaseWeightPercent;
  return weight.clamp(minLeaseWeightPercent, maxLeaseWeightPercent).toDouble();
}

String? normalizeLeaseText(Object? value, {int maxLength = 120}) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length <= maxLength
      ? trimmed
      : trimmed.substring(0, maxLength);
}

class RouteLease {
  final String id;
  final String provider;
  final String account;
  final int createdAt;
  final int expiresAt;
  final double weightPercent;
  final String? client;
  final String? idempotencyKey;

  const RouteLease({
    required this.id,
    required this.provider,
    required this.account,
    required this.createdAt,
    required this.expiresAt,
    required this.weightPercent,
    this.client,
    this.idempotencyKey,
  });

  bool activeAt(int now) => expiresAt > now;

  Map<String, dynamic> toJson() => {
        'id': id,
        'provider': provider,
        'account': account,
        'created_at': createdAt,
        'expires_at': expiresAt,
        'weight_percent': weightPercent,
        if (client != null) 'client': client,
        if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
      };

  factory RouteLease.fromJson(Map<String, dynamic> json) {
    final id = normalizeLeaseText(json['id'], maxLength: 96);
    final createdAt = (json['created_at'] as num?)?.toInt();
    final expiresAt = (json['expires_at'] as num?)?.toInt();
    if (id == null || createdAt == null || expiresAt == null) {
      throw const FormatException('invalid lease');
    }
    return RouteLease(
      id: id,
      provider: normalizeLeaseProvider(json['provider'] as String? ?? ''),
      account: normalizeLeaseAccount(json['account'] as String?),
      createdAt: createdAt,
      expiresAt: expiresAt,
      weightPercent: normalizeLeaseWeight(json['weight_percent']),
      client: normalizeLeaseText(json['client']),
      idempotencyKey: normalizeLeaseText(json['idempotency_key']),
    );
  }
}

class LeaseTargetDiscount {
  final String provider;
  final String account;
  final double discountPercent;
  final int leases;
  final int? expiresAt;

  const LeaseTargetDiscount({
    required this.provider,
    required this.account,
    required this.discountPercent,
    required this.leases,
    required this.expiresAt,
  });

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'account': account,
        'discount_percent': discountPercent,
        'leases': leases,
        if (expiresAt != null) 'expires_at': expiresAt,
      };
}

class RouteLeaseReservation {
  final bool reserved;
  final bool reused;
  final String reason;
  final RouteLease? lease;
  final List<RouteLease> activeLeases;

  const RouteLeaseReservation({
    required this.reserved,
    required this.reused,
    required this.reason,
    required this.lease,
    required this.activeLeases,
  });
}

class RouteLeaseRelease {
  final bool released;
  final String reason;
  final RouteLease? lease;
  final List<RouteLease> activeLeases;

  const RouteLeaseRelease({
    required this.released,
    required this.reason,
    required this.lease,
    required this.activeLeases,
  });
}

abstract class RouteLeaseStore {
  List<RouteLease> active(int now);

  RouteLeaseReservation reserve({
    required String provider,
    required String account,
    required int now,
    required int leaseSeconds,
    required double weightPercent,
    String? client,
    String? idempotencyKey,
  });

  RouteLeaseRelease release({
    required String leaseId,
    required int now,
  });
}

class NoopRouteLeaseStore implements RouteLeaseStore {
  const NoopRouteLeaseStore();

  @override
  List<RouteLease> active(int now) => const [];

  @override
  RouteLeaseReservation reserve({
    required String provider,
    required String account,
    required int now,
    required int leaseSeconds,
    required double weightPercent,
    String? client,
    String? idempotencyKey,
  }) =>
      const RouteLeaseReservation(
        reserved: false,
        reused: false,
        reason: 'lease store unavailable',
        lease: null,
        activeLeases: [],
      );

  @override
  RouteLeaseRelease release({required String leaseId, required int now}) =>
      const RouteLeaseRelease(
        released: false,
        reason: 'lease store unavailable',
        lease: null,
        activeLeases: [],
      );
}

class InMemoryRouteLeaseStore implements RouteLeaseStore {
  final LeaseIdFactory idFactory;
  List<RouteLease> _leases = [];

  InMemoryRouteLeaseStore({LeaseIdFactory? idFactory})
      : idFactory = idFactory ?? randomLeaseId;

  @override
  List<RouteLease> active(int now) {
    _leases = _activeOnly(_leases, now);
    return List.unmodifiable(_leases);
  }

  @override
  RouteLeaseReservation reserve({
    required String provider,
    required String account,
    required int now,
    required int leaseSeconds,
    required double weightPercent,
    String? client,
    String? idempotencyKey,
  }) {
    _leases = _activeOnly(_leases, now);
    final request = _leaseFromRequest(
      provider: provider,
      account: account,
      now: now,
      leaseSeconds: leaseSeconds,
      weightPercent: weightPercent,
      client: client,
      idempotencyKey: idempotencyKey,
      idFactory: idFactory,
    );
    final existing = _matchingIdempotencyLease(_leases, request);
    if (existing != null) {
      return RouteLeaseReservation(
        reserved: true,
        reused: true,
        reason: 'existing lease reused',
        lease: existing,
        activeLeases: List.unmodifiable(_leases),
      );
    }
    if (_leases.length >= maxActiveLeases) {
      return RouteLeaseReservation(
        reserved: false,
        reused: false,
        reason: 'too many active leases',
        lease: null,
        activeLeases: List.unmodifiable(_leases),
      );
    }
    _leases = [..._leases, request];
    return RouteLeaseReservation(
      reserved: true,
      reused: false,
      reason: 'lease reserved',
      lease: request,
      activeLeases: List.unmodifiable(_leases),
    );
  }

  @override
  RouteLeaseRelease release({required String leaseId, required int now}) {
    _leases = _activeOnly(_leases, now);
    final normalized = leaseId.trim();
    RouteLease? found;
    final kept = <RouteLease>[];
    for (final lease in _leases) {
      if (lease.id == normalized) {
        found = lease;
      } else {
        kept.add(lease);
      }
    }
    _leases = kept;
    return RouteLeaseRelease(
      released: found != null,
      reason: found == null ? 'lease not found' : 'lease released',
      lease: found,
      activeLeases: List.unmodifiable(_leases),
    );
  }
}

class FileRouteLeaseStore implements RouteLeaseStore {
  final Directory Function() dirFactory;
  final LeaseIdFactory idFactory;

  const FileRouteLeaseStore({
    this.dirFactory = leaseDir,
    this.idFactory = randomLeaseId,
  });

  File _dataFile(Directory dir) => File('${dir.path}/route_leases.json');

  File _lockFile(Directory dir) => File('${dir.path}/route_leases.lock');

  @override
  List<RouteLease> active(int now) => _withLock((dir) {
        final active = _activeOnly(_readUnlocked(_dataFile(dir)), now);
        _writeUnlocked(_dataFile(dir), active);
        return List.unmodifiable(active);
      });

  @override
  RouteLeaseReservation reserve({
    required String provider,
    required String account,
    required int now,
    required int leaseSeconds,
    required double weightPercent,
    String? client,
    String? idempotencyKey,
  }) =>
      _withLock((dir) {
        final file = _dataFile(dir);
        final active = _activeOnly(_readUnlocked(file), now);
        final request = _leaseFromRequest(
          provider: provider,
          account: account,
          now: now,
          leaseSeconds: leaseSeconds,
          weightPercent: weightPercent,
          client: client,
          idempotencyKey: idempotencyKey,
          idFactory: idFactory,
        );
        final existing = _matchingIdempotencyLease(active, request);
        if (existing != null) {
          _writeUnlocked(file, active);
          return RouteLeaseReservation(
            reserved: true,
            reused: true,
            reason: 'existing lease reused',
            lease: existing,
            activeLeases: List.unmodifiable(active),
          );
        }
        if (active.length >= maxActiveLeases) {
          _writeUnlocked(file, active);
          return RouteLeaseReservation(
            reserved: false,
            reused: false,
            reason: 'too many active leases',
            lease: null,
            activeLeases: List.unmodifiable(active),
          );
        }
        final next = [...active, request];
        _writeUnlocked(file, next);
        return RouteLeaseReservation(
          reserved: true,
          reused: false,
          reason: 'lease reserved',
          lease: request,
          activeLeases: List.unmodifiable(next),
        );
      });

  @override
  RouteLeaseRelease release({required String leaseId, required int now}) =>
      _withLock((dir) {
        final file = _dataFile(dir);
        final active = _activeOnly(_readUnlocked(file), now);
        final normalized = leaseId.trim();
        RouteLease? found;
        final kept = <RouteLease>[];
        for (final lease in active) {
          if (lease.id == normalized) {
            found = lease;
          } else {
            kept.add(lease);
          }
        }
        _writeUnlocked(file, kept);
        return RouteLeaseRelease(
          released: found != null,
          reason: found == null ? 'lease not found' : 'lease released',
          lease: found,
          activeLeases: List.unmodifiable(kept),
        );
      });

  T _withLock<T>(T Function(Directory dir) run) {
    final dir = dirFactory();
    restrictOwnerOnlyDirectory(dir);
    final lockFile = _lockFile(dir);
    if (!lockFile.existsSync()) lockFile.createSync(recursive: true);
    restrictOwnerOnlyFile(lockFile);
    final lock = lockFile.openSync(mode: FileMode.write);
    try {
      lock.lockSync(FileLock.blockingExclusive);
      return run(dir);
    } finally {
      try {
        lock.unlockSync();
      } catch (_) {}
      lock.closeSync();
    }
  }
}

List<RouteLease> _readUnlocked(File file) {
  try {
    if (!file.existsSync() || file.lengthSync() > 1024 * 1024) return [];
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((entry) {
          try {
            return RouteLease.fromJson(entry.cast<String, dynamic>());
          } catch (_) {
            return null;
          }
        })
        .whereType<RouteLease>()
        .toList();
  } catch (_) {
    return [];
  }
}

void _writeUnlocked(File file, List<RouteLease> leases) {
  final tmp = File('${file.path}.$pid.tmp');
  if (!tmp.existsSync()) tmp.createSync(recursive: true);
  restrictOwnerOnlyFile(tmp);
  tmp.writeAsStringSync(
      jsonEncode(leases.map((lease) => lease.toJson()).toList()));
  tmp.renameSync(file.path);
  restrictOwnerOnlyFile(file);
}

List<RouteLease> _activeOnly(List<RouteLease> leases, int now) =>
    leases.where((lease) => lease.activeAt(now)).toList()
      ..sort((a, b) => a.expiresAt.compareTo(b.expiresAt));

RouteLease _leaseFromRequest({
  required String provider,
  required String account,
  required int now,
  required int leaseSeconds,
  required double weightPercent,
  required LeaseIdFactory idFactory,
  String? client,
  String? idempotencyKey,
}) {
  final seconds = normalizeLeaseSeconds(leaseSeconds);
  return RouteLease(
    id: idFactory(),
    provider: normalizeLeaseProvider(provider),
    account: normalizeLeaseAccount(account),
    createdAt: now,
    expiresAt: now + seconds,
    weightPercent: normalizeLeaseWeight(weightPercent),
    client: normalizeLeaseText(client),
    idempotencyKey: normalizeLeaseText(idempotencyKey),
  );
}

RouteLease? _matchingIdempotencyLease(
  List<RouteLease> active,
  RouteLease request,
) {
  final key = request.idempotencyKey;
  if (key == null) return null;
  for (final lease in active) {
    if (lease.idempotencyKey == key &&
        lease.provider == request.provider &&
        lease.account == request.account) {
      return lease;
    }
  }
  return null;
}

List<LeaseTargetDiscount> leaseDiscounts(Iterable<RouteLease> leases) {
  final grouped = <String, List<RouteLease>>{};
  for (final lease in leases) {
    final key = '${lease.provider}\u0000${lease.account}';
    grouped.putIfAbsent(key, () => []).add(lease);
  }
  final out = <LeaseTargetDiscount>[];
  for (final leasesForTarget in grouped.values) {
    final first = leasesForTarget.first;
    final total = leasesForTarget
        .fold<double>(0, (sum, lease) => sum + lease.weightPercent)
        .clamp(0.0, 100.0)
        .toDouble();
    final expiresAt = leasesForTarget
        .map((lease) => lease.expiresAt)
        .reduce((a, b) => a < b ? a : b);
    out.add(LeaseTargetDiscount(
      provider: first.provider,
      account: first.account,
      discountPercent: total,
      leases: leasesForTarget.length,
      expiresAt: expiresAt,
    ));
  }
  out.sort((a, b) {
    final byProvider = a.provider.compareTo(b.provider);
    return byProvider != 0 ? byProvider : a.account.compareTo(b.account);
  });
  return out;
}

double leaseDiscountFor(
  Iterable<RouteLease> leases,
  String provider,
  String account,
) {
  final normalizedProvider = normalizeLeaseProvider(provider);
  final normalizedAccount = normalizeLeaseAccount(account);
  return leases
      .where((lease) =>
          lease.provider == normalizedProvider &&
          lease.account == normalizedAccount)
      .fold<double>(0, (sum, lease) => sum + lease.weightPercent)
      .clamp(0.0, 100.0)
      .toDouble();
}

String randomLeaseId() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}
