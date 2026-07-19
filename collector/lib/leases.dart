import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'file_guard.dart';
import 'provider_ids.dart';
import 'storage_keys.dart';
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
  final normalized =
      canonicalizeProviderId(_normalizeIdPart(value).toLowerCase());
  return normalized.isEmpty ? 'unknown' : normalized;
}

String normalizeLeaseAccount(String? value) {
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty) return 'default';
  final clean = StringBuffer();
  for (final rune in trimmed.runes) {
    if (rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f)) continue;
    clean.writeCharCode(rune);
  }
  final normalized = clean.toString();
  return normalized.isEmpty ? 'default' : normalized;
}

String _leaseAccountKey(String? account) =>
    accountIdentityDigest(normalizeLeaseAccount(account));

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

class RouteLeaseTarget {
  final String provider;
  final String account;

  const RouteLeaseTarget({
    required this.provider,
    required this.account,
  });
}

class RouteLeaseSelection {
  final RouteLeaseTarget? target;
  final String reason;

  const RouteLeaseSelection.selected(RouteLeaseTarget target)
      : this._(target, 'lease target selected');

  const RouteLeaseSelection.unavailable(String reason) : this._(null, reason);

  const RouteLeaseSelection._(this.target, this.reason);
}

typedef RouteLeaseSelector = RouteLeaseSelection Function(
  List<RouteLease> activeLeases,
);

typedef RouteLeaseReusePredicate = bool Function(RouteLease lease);

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

  /// Selects a target from the latest active leases and creates its lease as
  /// one store transaction. File-backed stores serialize independent processes.
  /// The file store combines an exclusive claim with its native lock so POSIX
  /// isolates and independent processes observe the same transaction boundary.
  /// A matching idempotency key that fails [reuseWhere] is a scope conflict and
  /// is never reassigned.
  RouteLeaseReservation selectAndReserve({
    required RouteLeaseSelector select,
    required int now,
    required int leaseSeconds,
    required double weightPercent,
    String? client,
    String? idempotencyKey,
    RouteLeaseReusePredicate? reuseWhere,
  });

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
  RouteLeaseReservation selectAndReserve({
    required RouteLeaseSelector select,
    required int now,
    required int leaseSeconds,
    required double weightPercent,
    String? client,
    String? idempotencyKey,
    RouteLeaseReusePredicate? reuseWhere,
  }) {
    final selection = select(const []);
    if (selection.target == null) {
      return RouteLeaseReservation(
        reserved: false,
        reused: false,
        reason: selection.reason,
        lease: null,
        activeLeases: const [],
      );
    }
    return const RouteLeaseReservation(
      reserved: false,
      reused: false,
      reason: 'lease store unavailable',
      lease: null,
      activeLeases: [],
    );
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
  RouteLeaseReservation selectAndReserve({
    required RouteLeaseSelector select,
    required int now,
    required int leaseSeconds,
    required double weightPercent,
    String? client,
    String? idempotencyKey,
    RouteLeaseReusePredicate? reuseWhere,
  }) {
    _leases = _activeOnly(_leases, now);
    final reservation = _selectAndReserve(
      active: _leases,
      select: select,
      now: now,
      leaseSeconds: leaseSeconds,
      weightPercent: weightPercent,
      client: client,
      idempotencyKey: idempotencyKey,
      reuseWhere: reuseWhere,
      idFactory: idFactory,
    );
    _leases = List.of(reservation.activeLeases);
    return reservation;
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
    if (_idempotencyKeyTargetsDifferentLease(_leases, request)) {
      return RouteLeaseReservation(
        reserved: false,
        reused: false,
        reason: 'idempotency key belongs to a different lease target',
        lease: null,
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
  List<RouteLease> active(int now) {
    // Leases are advisory; a lock or IO failure must never break the read-only
    // routing tools that consult them (suggest_provider, decide_now). Degrade
    // to no active leases, matching NoopRouteLeaseStore.
    try {
      return _withLock((dir) {
        final active = _activeOnly(_readUnlocked(_dataFile(dir)), now);
        _writeUnlocked(_dataFile(dir), active);
        return List.unmodifiable(active);
      });
    } catch (_) {
      return const [];
    }
  }

  @override
  RouteLeaseReservation selectAndReserve({
    required RouteLeaseSelector select,
    required int now,
    required int leaseSeconds,
    required double weightPercent,
    String? client,
    String? idempotencyKey,
    RouteLeaseReusePredicate? reuseWhere,
  }) {
    try {
      return _withLock((dir) {
        final file = _dataFile(dir);
        final active = _activeOnly(_readUnlocked(file), now);
        final reservation = _selectAndReserve(
          active: active,
          select: select,
          now: now,
          leaseSeconds: leaseSeconds,
          weightPercent: weightPercent,
          client: client,
          idempotencyKey: idempotencyKey,
          reuseWhere: reuseWhere,
          idFactory: idFactory,
        );
        _writeUnlocked(file, reservation.activeLeases);
        return reservation;
      });
    } catch (_) {
      return const RouteLeaseReservation(
        reserved: false,
        reused: false,
        reason: 'lease store unavailable',
        lease: null,
        activeLeases: [],
      );
    }
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
    try {
      return _withLock((dir) {
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
        if (_idempotencyKeyTargetsDifferentLease(active, request)) {
          _writeUnlocked(file, active);
          return RouteLeaseReservation(
            reserved: false,
            reused: false,
            reason: 'idempotency key belongs to a different lease target',
            lease: null,
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
    } catch (_) {
      return const RouteLeaseReservation(
        reserved: false,
        reused: false,
        reason: 'lease store unavailable',
        lease: null,
        activeLeases: [],
      );
    }
  }

  @override
  RouteLeaseRelease release({required String leaseId, required int now}) {
    try {
      return _withLock((dir) {
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
    } catch (_) {
      return const RouteLeaseRelease(
        released: false,
        reason: 'lease store unavailable',
        lease: null,
        activeLeases: [],
      );
    }
  }

  T _withLock<T>(T Function(Directory dir) run) {
    final dir = dirFactory();
    restrictOwnerOnlyDirectory(dir);
    final lockFile = _lockFile(dir);
    if (!lockFile.existsSync()) {
      try {
        lockFile.createSync(recursive: true, exclusive: true);
      } on FileSystemException {
        if (!lockFile.existsSync()) rethrow;
      }
    }
    if (FileSystemEntity.typeSync(lockFile.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('invalid lease lock file', lockFile.path);
    }
    restrictOwnerOnlyFile(lockFile);
    final guard = acquireInterprocessFileGuardSync(
      lockFile,
      hardenClaim: restrictOwnerOnlyFile,
    );
    try {
      return run(dir);
    } finally {
      guard.release();
    }
  }
}

List<RouteLease> _readUnlocked(File file) {
  try {
    if (!file.existsSync() || file.lengthSync() > 1024 * 1024) return [];
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! List<Object?>) return [];
    return decoded
        .whereType<Map<Object?, Object?>>()
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
  final tmp = _createLeaseTemporaryFile(file);
  try {
    restrictOwnerOnlyFile(tmp);
    tmp.writeAsStringSync(
      jsonEncode(leases.map((lease) => lease.toJson()).toList()),
      flush: true,
    );
    tmp.renameSync(file.path);
    restrictOwnerOnlyFile(file);
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
  }
}

File _createLeaseTemporaryFile(File target) {
  for (var attempt = 0; attempt < 16; attempt++) {
    final temporary = File('${target.path}.$pid.${randomLeaseId()}.tmp');
    try {
      temporary.createSync(exclusive: true);
      return temporary;
    } on FileSystemException {
      if (!temporary.existsSync()) rethrow;
    }
  }
  throw FileSystemException(
    'could not create lease temporary file',
    target.path,
  );
}

List<RouteLease> _activeOnly(List<RouteLease> leases, int now) =>
    leases.where((lease) => lease.activeAt(now)).toList()
      ..sort((a, b) => a.expiresAt.compareTo(b.expiresAt));

RouteLeaseReservation _selectAndReserve({
  required List<RouteLease> active,
  required RouteLeaseSelector select,
  required int now,
  required int leaseSeconds,
  required double weightPercent,
  required LeaseIdFactory idFactory,
  String? client,
  String? idempotencyKey,
  RouteLeaseReusePredicate? reuseWhere,
}) {
  final normalizedKey = normalizeLeaseText(idempotencyKey);
  if (normalizedKey != null) {
    var conflictsWithScope = false;
    for (final lease in active) {
      if (lease.idempotencyKey == normalizedKey) {
        if (reuseWhere != null && !reuseWhere(lease)) {
          conflictsWithScope = true;
          continue;
        }
        return RouteLeaseReservation(
          reserved: true,
          reused: true,
          reason: 'reused the active lease for this idempotency key',
          lease: lease,
          activeLeases: List.unmodifiable(active),
        );
      }
    }
    if (conflictsWithScope) {
      return RouteLeaseReservation(
        reserved: false,
        reused: false,
        reason: 'idempotency key belongs to a lease outside this request',
        lease: null,
        activeLeases: List.unmodifiable(active),
      );
    }
  }
  final selection = select(List.unmodifiable(active));
  final target = selection.target;
  if (target == null) {
    return RouteLeaseReservation(
      reserved: false,
      reused: false,
      reason: selection.reason,
      lease: null,
      activeLeases: List.unmodifiable(active),
    );
  }
  if (active.length >= maxActiveLeases) {
    return RouteLeaseReservation(
      reserved: false,
      reused: false,
      reason: 'too many active leases',
      lease: null,
      activeLeases: List.unmodifiable(active),
    );
  }
  final request = _leaseFromRequest(
    provider: target.provider,
    account: target.account,
    now: now,
    leaseSeconds: leaseSeconds,
    weightPercent: weightPercent,
    client: client,
    idempotencyKey: normalizedKey,
    idFactory: idFactory,
  );
  final next = [...active, request];
  return RouteLeaseReservation(
    reserved: true,
    reused: false,
    reason: 'lease reserved',
    lease: request,
    activeLeases: List.unmodifiable(next),
  );
}

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

bool _idempotencyKeyTargetsDifferentLease(
  List<RouteLease> active,
  RouteLease request,
) {
  final key = request.idempotencyKey;
  if (key == null) return false;
  return active.any(
    (lease) =>
        lease.idempotencyKey == key &&
        (lease.provider != request.provider ||
            lease.account != request.account),
  );
}

List<LeaseTargetDiscount> leaseDiscounts(Iterable<RouteLease> leases) {
  final grouped = <String, List<RouteLease>>{};
  for (final lease in leases) {
    final key = '${lease.provider}\u0000${_leaseAccountKey(lease.account)}';
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
  final accountKey = _leaseAccountKey(account);
  return leases
      .where((lease) =>
          lease.provider == normalizedProvider &&
          _leaseAccountKey(lease.account) == accountKey)
      .fold<double>(0, (sum, lease) => sum + lease.weightPercent)
      .clamp(0.0, 100.0)
      .toDouble();
}

String randomLeaseId() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}
