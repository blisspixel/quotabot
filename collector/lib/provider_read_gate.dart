import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'credential_identity.dart';
import 'file_guard.dart';
import 'provider_ids.dart';
import 'util.dart';

/// Independent metadata surfaces must not clear each other's cooldowns.
enum ProviderReadPurpose { usage, profile }

/// Bounded diagnostics only. Never persist provider bodies or exception text.
enum ProviderReadFailure {
  rateLimited,
  serviceUnavailable,
  timedOut,
  forbidden,
  unavailable,
}

enum ProviderReadDeferralReason { cooldown, busy, storageUnavailable, failed }

class ProviderReadDisposition {
  final ProviderReadFailure? failure;
  final int? httpStatus;
  final int? retryAfterSeconds;

  /// A completed operation with no cooldown. This does not itself prove quota.
  /// An adapter may also use it for a 401 before its authorized token fallback.
  const ProviderReadDisposition.completed()
      : failure = null,
        httpStatus = null,
        retryAfterSeconds = null;

  const ProviderReadDisposition.failed(
    ProviderReadFailure this.failure, {
    this.httpStatus,
    this.retryAfterSeconds,
  });

  factory ProviderReadDisposition.httpFailure(
    int status, {
    int? retryAfterSeconds,
  }) =>
      ProviderReadDisposition.failed(
        switch (status) {
          429 => ProviderReadFailure.rateLimited,
          403 => ProviderReadFailure.forbidden,
          408 || 504 => ProviderReadFailure.timedOut,
          >= 500 => ProviderReadFailure.serviceUnavailable,
          _ => ProviderReadFailure.unavailable,
        },
        httpStatus: status,
        retryAfterSeconds: retryAfterSeconds,
      );
}

class ProviderReadDeferral {
  final ProviderReadDeferralReason reason;
  final ProviderReadFailure? failure;
  final int? httpStatus;
  final int? retryAfterSeconds;

  const ProviderReadDeferral(
    this.reason, {
    this.failure,
    this.httpStatus,
    this.retryAfterSeconds,
  });
}

/// Owns the actual request lifetime, independently of a caller's timeout.
/// Adapters must track the original future, never only a `.timeout` wrapper.
class ProviderReadOperation {
  final List<Future<void>> _pending = [];

  Future<T> track<T>(Future<T> request) {
    _pending
        .add(request.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    return request;
  }

  Future<void> get _settled async {
    // Include work registered while another tracked request is finishing.
    var count = 0;
    while (count < _pending.length) {
      final batch = _pending.sublist(count);
      count = _pending.length;
      await Future.wait(batch);
    }
  }

  /// Metadata GET with cooperative cancellation on the existing HTTP client.
  /// If a custom client ignores abort, the future and guard stay live until the
  /// original response settles. The shared client is never closed here.
  Future<http.Response> get(
    http.Client client,
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    if (timeout.inMicroseconds <= 0) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    final abort = Completer<void>();
    var expired = false;
    final timer = Timer(timeout, () {
      expired = true;
      abort.complete();
    });
    try {
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..headers.addAll(headers);
      final response = await track(
        client.send(request).then(http.Response.fromStream),
      );
      if (expired) throw TimeoutException('provider metadata deadline');
      return response;
    } on http.RequestAbortedException {
      if (expired) throw TimeoutException('provider metadata deadline');
      rethrow;
    } finally {
      timer.cancel();
    }
  }
}

/// Serializes one provider / exact credential generation / metadata purpose.
///
/// This is not a subscription-pool limiter: two grants for one pool remain two
/// scopes until their relationship is established independently. Grant refresh
/// is outside this service. State contains no token, account ID, plan or quota.
///
/// A pending record is written before outbound work. After a process exits, its
/// scope can recover at that record's bounded deadline once the native guard is
/// reacquired. A failed final write retains a known provider deadline in this
/// isolate, but cannot promise durable cross-process enforcement of that value.
class ProviderReadGate {
  static const _schema = 'quotabot.provider-read.v1';
  static const _maxStateBytes = 2048;
  static const _backoffSeconds = [60, 120, 300, 600, 1200];
  static const _interruptedRecoverySeconds = 120;
  static const _maxUnpersistedDeadlines = 128;
  static final _maxInteger = BigInt.from(0x7fffffffffffffff);
  static final Map<String, _ReadState> _unpersistedDeadlines = {};
  static final Set<Future<void>> _activeOperations = {};

  /// Keeps a worker isolate alive after it publishes a bounded fleet result.
  /// The worker must send that result before awaiting this drain, then exit only
  /// after it completes. Isolate.run on a timed-out collector alone terminates
  /// outstanding requests before their guards can be released.
  static Future<void> drainActive() async {
    while (_activeOperations.isNotEmpty) {
      await Future.wait(_activeOperations.toList(growable: false));
    }
  }

  final Directory? _directory;
  final int Function() _clock;
  final int Function(int upperBound) _jitter;
  final void Function(Directory) _hardenDirectory;
  final GuardFileHardener _hardenFile;
  final Duration acquisitionTimeout;

  ProviderReadGate({
    Directory? directory,
    int Function()? clock,
    int Function(int upperBound)? jitter,
    void Function(Directory)? hardenDirectory,
    GuardFileHardener? hardenFile,
    this.acquisitionTimeout = const Duration(milliseconds: 100),
  })  : _directory = directory,
        _clock = clock ?? nowEpoch,
        _jitter = jitter ?? Random.secure().nextInt,
        _hardenDirectory = hardenDirectory ?? enforceOwnerOnlyDirectory,
        _hardenFile = hardenFile ?? enforceOwnerOnlyFile;

  Future<T> run<T>({
    required String provider,
    required String credentialIdentity,
    required ProviderReadPurpose purpose,
    required Future<T> Function(ProviderReadOperation) attempt,
    required ProviderReadDisposition Function(T) classify,
    required FutureOr<T> Function(ProviderReadDeferral) deferred,
  }) async {
    if (!kCurrentProviderIds.contains(provider) ||
        !isOpaqueCredentialIdentity(credentialIdentity)) {
      return deferred(const ProviderReadDeferral(
        ProviderReadDeferralReason.storageUnavailable,
      ));
    }
    InterprocessFileGuard guard;
    late File stateFile;
    try {
      final dir = _prepareDirectory();
      final digest = sha256.convert(utf8.encode(
        'quotabot-provider-read-v1\u0000$provider\u0000'
        '$credentialIdentity\u0000${purpose.name}',
      ));
      stateFile = File('${dir.path}/$digest.json');
      final lock = File('${stateFile.path}.lock');
      _prepareLock(lock);
      guard = await acquireInterprocessFileGuard(
        lock,
        hardenClaim: _hardenFile,
        acquisitionTimeout: acquisitionTimeout,
        reclaimSameProcessClaims: false,
      );
    } catch (error) {
      return deferred(ProviderReadDeferral(
        error is FileSystemException &&
                error.message == 'timed out acquiring file guard'
            ? ProviderReadDeferralReason.busy
            : ProviderReadDeferralReason.storageUnavailable,
      ));
    }

    final completion = Completer<void>();
    _activeOperations.add(completion.future);
    final operation = ProviderReadOperation();
    try {
      var previous = _readState(stateFile);
      final now = _now();
      _unpersistedDeadlines
          .removeWhere((_, state) => state.deadline! <= BigInt.from(now));
      final remembered = _unpersistedDeadlines[stateFile.absolute.path];
      if (remembered != null &&
          (previous == null || remembered.deadline! > previous.deadline!)) {
        previous = remembered;
      }
      if (_unpersistedDeadlines.length >= _maxUnpersistedDeadlines &&
          remembered == null) {
        return await deferred(const ProviderReadDeferral(
          ProviderReadDeferralReason.storageUnavailable,
        ));
      }
      if (previous != null && previous.deadline! > BigInt.from(now)) {
        return await deferred(previous.deferral(now));
      }
      final failures = previous?.failures ?? 0;
      _writeState(
          stateFile,
          _ReadState.pending(
            now,
            failures,
            BigInt.from(now) + BigInt.from(_interruptedRecoverySeconds),
          ));
      T result;
      ProviderReadDisposition disposition;
      try {
        result = await attempt(operation);
        disposition = classify(result);
      } catch (_) {
        disposition = const ProviderReadDisposition.failed(
          ProviderReadFailure.unavailable,
        );
        final failure = _failureState(disposition, failures);
        await operation._settled;
        _persistFailure(stateFile, failure);
        return await deferred(failure.deferral(
          _now(),
          reason: ProviderReadDeferralReason.failed,
        ));
      }
      // A timed-out wrapper can finish before its raw request. Keep the guard
      // and pending marker until every registered request has actually settled.
      await operation._settled;
      if (disposition.failure == null) {
        _requireRegularOrMissing(stateFile.path);
        stateFile.deleteSync();
        _unpersistedDeadlines.remove(stateFile.absolute.path);
      } else {
        _persistFailure(stateFile, _failureState(disposition, failures));
      }
      return result;
    } catch (_) {
      return await deferred(const ProviderReadDeferral(
        ProviderReadDeferralReason.storageUnavailable,
      ));
    } finally {
      try {
        await operation._settled;
        guard.release();
      } finally {
        _activeOperations.remove(completion.future);
        completion.complete();
      }
    }
  }

  void _persistFailure(File file, _ReadState state) {
    // Retain the exact known deadline if disk persistence fails. A different
    // process can only enforce the last successfully persisted record.
    _unpersistedDeadlines[file.absolute.path] = state;
    _writeState(file, state);
    _unpersistedDeadlines.remove(file.absolute.path);
  }

  int _now() {
    final value = _clock();
    if (value < 0) throw const FormatException('invalid metadata clock');
    return value;
  }

  _ReadState _failureState(ProviderReadDisposition result, int previous) {
    final now = _now();
    final failures = min(previous + 1, _backoffSeconds.length);
    final backoff = _backoffSeconds[failures - 1];
    final header = result.retryAfterSeconds;
    final delay = header != null && header >= 0
        ? header
        : backoff + _jitter(backoff ~/ 10 + 1).clamp(0, backoff ~/ 10);
    final status = result.httpStatus;
    return _ReadState(
      observedAt: now,
      failures: failures,
      failure: result.failure!,
      httpStatus:
          status != null && status >= 100 && status <= 599 ? status : null,
      // BigInt preserves a valid long header without integer wraparound or a
      // local backoff cap shortening the provider's deadline.
      deadline: BigInt.from(now) + BigInt.from(delay),
    );
  }

  Directory _prepareDirectory() {
    Directory dir;
    if (_directory case final supplied?) {
      dir = supplied;
    } else {
      final root = quotabotDir('');
      _requireDirectory(root.path);
      dir = Directory('${root.path}/provider_read_gates');
    }
    final type = FileSystemEntity.typeSync(dir.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) dir.createSync(recursive: true);
    _requireDirectory(dir.path);
    _hardenDirectory(dir);
    return dir;
  }

  void _prepareLock(File lock) {
    _requireRegularOrMissing(lock.path);
    var created = false;
    if (!lock.existsSync()) {
      try {
        lock.createSync(exclusive: true);
        created = true;
      } on FileSystemException {
        if (!lock.existsSync()) rethrow;
      }
    }
    _requireRegularOrMissing(lock.path);
    if (created) _hardenFile(lock);
    _requireRegularOrMissing('${lock.path}.claim');
  }

  _ReadState? _readState(File file) {
    _requireRegularOrMissing(file.path);
    if (!file.existsSync()) return null;
    if (file.lengthSync() > _maxStateBytes) {
      throw const FormatException('metadata gate state too large');
    }
    final value = jsonDecode(file.readAsStringSync());
    if (value is! Map<String, dynamic> || value['schema'] != _schema) {
      throw const FormatException('invalid metadata gate schema');
    }
    final pending = value['pending'];
    final observed = value['observed_at'];
    final failures = value['failures'];
    if (pending is! bool ||
        observed is! int ||
        observed < 0 ||
        failures is! int ||
        failures < 0 ||
        failures > _backoffSeconds.length) {
      throw const FormatException('invalid metadata gate state');
    }
    const common = {
      'schema',
      'pending',
      'observed_at',
      'failures',
      'retry_not_before',
    };
    final deadlineText = value['retry_not_before'];
    if (deadlineText is! String ||
        !RegExp(r'^[0-9]{1,20}$').hasMatch(deadlineText)) {
      throw const FormatException('invalid metadata gate deadline');
    }
    final deadline = BigInt.parse(deadlineText);
    if (deadline < BigInt.from(observed) ||
        deadline > _maxInteger * BigInt.two) {
      throw const FormatException('invalid metadata gate deadline');
    }
    if (pending) {
      if (value.keys.any((key) => !common.contains(key)) ||
          deadline - BigInt.from(observed) !=
              BigInt.from(_interruptedRecoverySeconds)) {
        throw const FormatException('invalid pending metadata gate state');
      }
      return _ReadState.pending(observed, failures, deadline);
    }
    const allowed = {...common, 'failure', 'http_status'};
    final failure = ProviderReadFailure.values
        .where((kind) => kind.name == value['failure'])
        .firstOrNull;
    final status = value['http_status'];
    if (failure == null ||
        failures == 0 ||
        value.keys.any((key) => !allowed.contains(key)) ||
        (status != null && (status is! int || status < 100 || status > 599))) {
      throw const FormatException('invalid metadata gate cooldown');
    }
    return _ReadState(
      observedAt: observed,
      failures: failures,
      failure: failure,
      httpStatus: status as int?,
      deadline: deadline,
    );
  }

  void _writeState(File file, _ReadState state) {
    _requireRegularOrMissing(file.path);
    final suffix = base64UrlEncode(List<int>.generate(
      18,
      (_) => Random.secure().nextInt(256),
    )).replaceAll('=', '');
    final temporary = File('${file.path}.$pid.$suffix.tmp');
    temporary.createSync(exclusive: true);
    try {
      _hardenFile(temporary);
      temporary.writeAsStringSync(
          jsonEncode({
            'schema': _schema,
            'pending': state.pending,
            'observed_at': state.observedAt,
            'failures': state.failures,
            'retry_not_before': state.deadline.toString(),
            if (!state.pending) ...{
              'failure': state.failure!.name,
              if (state.httpStatus != null) 'http_status': state.httpStatus,
            },
          }),
          flush: true);
      _requireRegularOrMissing(file.path);
      temporary.renameSync(file.path);
    } finally {
      if (FileSystemEntity.typeSync(temporary.path, followLinks: false) ==
          FileSystemEntityType.file) {
        temporary.deleteSync();
      }
    }
  }
}

class _ReadState {
  final bool pending;
  final int observedAt;
  final int failures;
  final ProviderReadFailure? failure;
  final int? httpStatus;
  final BigInt? deadline;

  const _ReadState({
    required this.observedAt,
    required this.failures,
    required this.failure,
    required this.deadline,
    this.httpStatus,
  }) : pending = false;

  const _ReadState.pending(this.observedAt, this.failures, this.deadline)
      : pending = true,
        failure = ProviderReadFailure.unavailable,
        httpStatus = null;

  ProviderReadDeferral deferral(
    int now, {
    ProviderReadDeferralReason reason = ProviderReadDeferralReason.cooldown,
  }) {
    final remaining = deadline! - BigInt.from(now);
    return ProviderReadDeferral(
      reason,
      failure: failure,
      httpStatus: httpStatus,
      retryAfterSeconds: remaining.isNegative
          ? 0
          : remaining > ProviderReadGate._maxInteger
              ? 0x7fffffffffffffff
              : remaining.toInt(),
    );
  }
}

void _requireRegularOrMissing(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type != FileSystemEntityType.file &&
      type != FileSystemEntityType.notFound) {
    throw const FormatException('invalid metadata gate file');
  }
}

void _requireDirectory(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FormatException('invalid metadata gate directory');
  }
}
