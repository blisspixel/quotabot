import 'dart:async';
import 'dart:isolate';

import 'package:quotabot_collector/collector.dart'
    show collectAll, drainActiveAdapterCollections;
import 'package:quotabot_collector/http_client.dart';
import 'package:quotabot_collector/models.dart';
import 'package:quotabot_collector/provider_read_gate.dart';

/// A reader and its data must be sendable to a worker isolate. Production uses
/// the collector directly; test readers use synthetic metadata only.
typedef DesktopCollectionReader =
    Future<List<ProviderQuota>> Function(int generation, Object? data);

Future<List<ProviderQuota>> _readQuota(int generation, Object? data) =>
    collectAll();

/// One reusable owner of collection and any metadata requests that outlive a
/// bounded fleet result. Caller timeouts do not cancel its pending generation.
class DesktopCollectionWorker {
  final DesktopCollectionReader reader;
  final Object? readerData;
  final Completer<void> _exited = Completer<void>();
  Future<SendPort>? _startup;
  Completer<SendPort>? _ready;
  ReceivePort? _events;
  SendPort? _commands;
  _PendingCollection? _pending;
  int _generation = 0;
  bool _closing = false;
  bool _failed = false;
  bool _drained = false;

  DesktopCollectionWorker({this.reader = _readQuota, this.readerData}) {
    // A worker can fail before the dashboard asks to close it. Preserve that
    // error for close(), without turning it into an unhandled UI exception.
    unawaited(
      _exited.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  Future<List<ProviderQuota>> collect() {
    if (_closing || _failed) {
      return Future.error(
        StateError('Quota collection worker is unavailable.'),
      );
    }
    final current = _pending;
    if (current != null) return current.result.future;
    final request = _PendingCollection(++_generation);
    _pending = request;
    unawaited(_dispatch(request));
    return request.result.future;
  }

  Future<void> _dispatch(_PendingCollection request) async {
    try {
      final commands = await (_startup ??= _start());
      if (_closing || _failed) {
        _finishRequest(request, null);
      } else {
        commands.send(_Collect(request.generation));
      }
    } catch (_) {
      _fail();
    }
  }

  Future<SendPort> _start() async {
    final ready = _ready = Completer<SendPort>();
    unawaited(
      ready.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    final events = _events = ReceivePort();
    events.listen(_onEvent);
    try {
      await Isolate.spawn(
        _collectionWorker,
        _WorkerInput(events.sendPort, reader, readerData),
        onError: events.sendPort,
        onExit: events.sendPort,
        // An unexpected asynchronous error must not abandon a native guard by
        // killing just this isolate. Fail the UI request and request a drain.
        errorsAreFatal: false,
        debugName: 'quotabot-collection',
      );
    } catch (_) {
      events.close();
      _events = null;
      _failed = true;
      if (!_exited.isCompleted) _exited.complete();
      throw StateError('Quota collection worker could not start.');
    }
    return ready.future;
  }

  void _onEvent(Object? event) {
    switch (event) {
      case final SendPort commands:
        _commands = commands;
        final ready = _ready!;
        if (!ready.isCompleted) ready.complete(commands);
        if (_closing || _failed) commands.send(const _Close());
      case _Collected(:final generation, :final providers):
        final request = _pending;
        if (request != null && request.generation == generation) {
          _finishRequest(request, providers);
        }
      case _Drained():
        _drained = true;
      case null:
        if (!_drained) _fail();
        _events?.close();
        _events = null;
        if (!_exited.isCompleted) {
          if (_drained) {
            _exited.complete();
          } else {
            _exited.completeError(
              StateError('Quota collection worker exited before draining.'),
            );
          }
        }
      default:
        // Error-port messages can contain provider or filesystem diagnostics.
        // Only a bounded local failure crosses into the dashboard.
        _fail();
    }
  }

  void _finishRequest(
    _PendingCollection request,
    List<ProviderQuota>? providers,
  ) {
    if (!identical(_pending, request)) return;
    _pending = null;
    if (providers == null) {
      request.result.completeError(StateError('Quota collection failed.'));
    } else {
      request.result.complete(providers);
    }
  }

  void _fail() {
    _failed = true;
    final request = _pending;
    if (request != null) _finishRequest(request, null);
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        StateError('Quota collection worker is unavailable.'),
      );
    }
    _commands?.send(const _Close());
  }

  /// Stops dispatch and completes only after the active fleet and every tracked
  /// raw metadata request settle, their guards drain, and the worker exits.
  /// It deliberately has no timeout and never kills an isolate.
  Future<void> close() {
    if (_closing) return _exited.future;
    _closing = true;
    if (_startup == null) {
      _exited.complete();
    } else {
      _commands?.send(const _Close());
      // A worker still starting receives Close in its ready-message handler.
    }
    return _exited.future;
  }
}

/// Only the full application Quit path may bound a cooperative drain. A whole
/// process exit releases native ownership and leaves interrupted-read recovery
/// to the gate. Widget disposal uses close() instead; a timeout never kills one
/// worker while its parent process remains alive.
Future<void> waitForDesktopCollectionBeforeExit(
  Future<void>? closing, {
  required void Function() exitProcess,
  Duration grace = const Duration(seconds: 5),
}) async {
  if (closing == null) return;
  try {
    await closing.timeout(grace);
  } catch (_) {
    exitProcess();
  }
}

class _PendingCollection {
  final int generation;
  final Completer<List<ProviderQuota>> result = Completer();

  _PendingCollection(this.generation);
}

class _WorkerInput {
  final SendPort events;
  final DesktopCollectionReader reader;
  final Object? data;

  const _WorkerInput(this.events, this.reader, this.data);
}

class _Collect {
  final int generation;

  const _Collect(this.generation);
}

class _Collected {
  final int generation;
  final List<ProviderQuota>? providers;

  const _Collected(this.generation, this.providers);
}

class _Close {
  const _Close();
}

class _Drained {
  const _Drained();
}

void _collectionWorker(_WorkerInput input) {
  final commands = ReceivePort();
  var collecting = false;
  var closing = false;
  var draining = false;
  var lastGeneration = 0;

  Future<void> finishClose() async {
    if (!closing || collecting || draining) return;
    draining = true;
    // The outer fleet must finish first: it can still be setting up a gate.
    await drainActiveAdapterCollections();
    await ProviderReadGate.drainActive();
    // Closing a pooled client before original adapters settle would cancel
    // ungated metadata reads. After settlement it releases idle sockets so the
    // worker exits without waiting for a remote keep-alive timeout.
    closeSharedHttpClient();
    commands.close();
    input.events.send(const _Drained());
  }

  Future<void> collect(int generation) async {
    collecting = true;
    lastGeneration = generation;
    try {
      final providers = await input.reader(generation, input.data);
      input.events.send(_Collected(generation, providers));
    } catch (_) {
      input.events.send(_Collected(generation, null));
    } finally {
      collecting = false;
      await finishClose();
    }
  }

  commands.listen((Object? command) {
    if (command is _Close) {
      closing = true;
      unawaited(finishClose());
    } else if (command is _Collect && !closing) {
      if (collecting || command.generation <= lastGeneration) return;
      unawaited(collect(command.generation));
    }
  });
  input.events.send(commands.sendPort);
}
