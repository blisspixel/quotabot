import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const _chunkBytes = 64 * 1024;
const _infinite = 0xffffffff;

final class _Overlapped extends Struct {
  @UintPtr()
  external int internal;
  @UintPtr()
  external int internalHigh;
  @Uint32()
  external int offset;
  @Uint32()
  external int offsetHigh;
  @IntPtr()
  external int event;
}

class _PipeApi {
  _PipeApi() {
    // Resolve and verify the bundled bridge before creating owned resources.
    if (_nativePipeAbi() != 1) throw StateError('pipe input ABI unavailable');
    [
      getStdHandle,
      getFileType,
      createEvent,
      setEvent,
      resetEvent,
      closeHandle,
      wait,
      waitMany,
      currentProcess,
      currentThread,
      duplicate,
      cancel,
      cancelSync,
      sleep
    ];
  }
  final DynamicLibrary _dll = DynamicLibrary.open('kernel32.dll');
  late final getStdHandle =
      _dll.lookupFunction<IntPtr Function(Uint32), int Function(int)>(
    'GetStdHandle',
  );
  late final getFileType =
      _dll.lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
    'GetFileType',
  );
  late final createEvent = _dll.lookupFunction<
      IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Utf16>),
      int Function(Pointer<Void>, int, int, Pointer<Utf16>)>('CreateEventW');
  late final setEvent = _dll
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetEvent');
  late final resetEvent = _dll
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('ResetEvent');
  late final closeHandle = _dll
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  late final wait = _dll
      .lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
    'WaitForSingleObject',
  );
  late final waitMany = _dll.lookupFunction<
      Uint32 Function(Uint32, Pointer<IntPtr>, Int32, Uint32),
      int Function(int, Pointer<IntPtr>, int, int)>('WaitForMultipleObjects');
  late final currentProcess = _dll
      .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  late final currentThread = _dll
      .lookupFunction<IntPtr Function(), int Function()>('GetCurrentThread');
  late final duplicate = _dll.lookupFunction<
      Int32 Function(
        IntPtr,
        IntPtr,
        IntPtr,
        Pointer<IntPtr>,
        Uint32,
        Int32,
        Uint32,
      ),
      int Function(
          int, int, int, Pointer<IntPtr>, int, int, int)>('DuplicateHandle');
  final readPipe = _nativeReadPipe;
  late final cancel = _dll.lookupFunction<
      Int32 Function(IntPtr, Pointer<_Overlapped>),
      int Function(int, Pointer<_Overlapped>)>('CancelIoEx');
  late final cancelSync =
      _dll.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'CancelSynchronousIo',
  );
  late final sleep =
      _dll.lookupFunction<Void Function(Uint32), void Function(int)>('Sleep');

  int event({bool manual = true}) {
    final value = createEvent(nullptr, manual ? 1 : 0, 0, nullptr);
    if (value == 0) throw StateError('pipe event unavailable');
    return value;
  }
}

/// Owns Windows pipe reads without creating the SDK stdin socket.
/// Parent owns the shared events until worker exit. A timeout
/// never makes native completion, storage release, or thread reuse safe.
class WindowsPipeInput {
  final _PipeApi _api;
  final int _input;
  final Future<void> Function(Future<void> Function())?
      _startBoundaryForTesting;
  final int? _readRegistrationEventForTesting;
  final void Function()? _onReadRegistrationForTesting;
  final void Function()? _onPendingChunkForTesting;
  late final int _stop;
  late final int _permit;
  late final int _release;
  late final StreamController<List<int>> _controller;
  late final ReceivePort _messages;
  late final ReceivePort _exit;
  late final ReceivePort _errors;
  final _done = Completer<void>();
  Timer? _retry;
  int? _thread;
  int? _overlapped;
  Uint8List? _pending;
  bool _started = false;
  bool _stopping = false;
  bool _eligible = false;
  bool _needsPermit = false;
  bool _delivered = false;
  bool _settled = false;
  bool _workerExited = false;
  bool _spawnSettled = false;
  bool _spawnRequested = false;
  bool _failed = false;

  WindowsPipeInput(
    this._input, {
    Future<void> Function(Future<void> Function())? startBoundaryForTesting,
    int? readRegistrationEventForTesting,
    void Function()? onReadRegistrationForTesting,
    void Function()? onPendingChunkForTesting,
  })  : _api = _PipeApi(),
        _startBoundaryForTesting = startBoundaryForTesting,
        _readRegistrationEventForTesting = readRegistrationEventForTesting,
        _onReadRegistrationForTesting = onReadRegistrationForTesting,
        _onPendingChunkForTesting = onPendingChunkForTesting {
    if (_api.getFileType(_input) != 3) {
      throw ArgumentError('pipe input required');
    }
    _messages = ReceivePort();
    _exit = ReceivePort();
    _errors = ReceivePort();
    final owned = <int>[];
    try {
      _stop = _api.event();
      owned.add(_stop);
      _permit = _api.event(manual: false);
      owned.add(_permit);
      _release = _api.event();
    } catch (_) {
      for (final event in owned) {
        _api.closeHandle(event);
      }
      _messages.close();
      _exit.close();
      _errors.close();
      rethrow;
    }
    _controller = StreamController<List<int>>(
      sync: true,
      onListen: _start,
      onPause: () {},
      onResume: _deliver,
      onCancel: close,
    );
  }

  Stream<List<int>> get stream => _controller.stream;
  Stdin get stdin => _PipeStdin(stream);
  Future<void> get done => _done.future;

  void _start() {
    if (_stopping || _done.isCompleted) return;
    _started = true;
    _messages.listen(_message);
    _errors.listen((_) {
      _failed = true;
    });
    _exit.listen((_) {
      _workerExited = true;
      _finish();
    });
    unawaited(
      Future<void>.sync(
          () => _startBoundaryForTesting?.call(_spawn) ?? _spawn()).then(
        (_) {
          _spawnSettled = true;
          _finish();
        },
        onError: (Object _, StackTrace __) {
          _spawnSettled = true;
          if (!_spawnRequested) _workerExited = true;
          _fail();
          _finish();
        },
      ),
    );
  }

  Future<void> _spawn() async {
    if (_done.isCompleted || _workerExited) return;
    if (_spawnRequested) throw StateError('pipe worker already started');
    _spawnRequested = true;
    try {
      await Isolate.spawn(
        _readPipe,
        [
          _messages.sendPort,
          _input,
          _stop,
          _permit,
          _release,
          _readRegistrationEventForTesting ?? 0,
        ],
        onExit: _exit.sendPort,
        onError: _errors.sendPort,
      );
    } catch (_) {
      _workerExited = true;
      rethrow;
    }
  }

  void _message(dynamic value) {
    if (value is! List || value.isEmpty) return;
    switch (value[0]) {
      case 'ready':
        _thread = value[1] as int;
        _overlapped = value[2] as int;
        _eligible = true;
        if (_stopping || _failed) {
          _requestStop();
        } else if (!_controller.isPaused) {
          _api.setEvent(_permit);
        } else {
          _needsPermit = true;
          _delivered = true;
        }
      case 'chunk':
        if (_stopping || _failed) return;
        if (_pending != null || _needsPermit) {
          _fail();
          return;
        }
        _pending = value[1] as Uint8List;
        _needsPermit = true;
        _delivered = false;
        _onPendingChunkForTesting?.call();
        _deliver();
      case 'read_boundary':
        _onReadRegistrationForTesting?.call();
      case 'settled':
        _settled = true;
        _failed = _failed || value[1] == true;
        // A worker cannot yield or free native storage before cancellation
        // eligibility is synchronously revoked on this parent isolate.
        _eligible = false;
        _retry?.cancel();
        _retry = null;
        _api.setEvent(_release);
    }
  }

  void _deliver() {
    if (_stopping || _failed || _settled || _controller.isPaused) return;
    final chunk = _pending;
    if (chunk != null) {
      _pending = null;
      _controller.add(chunk);
      _delivered = true;
    }
    // add is synchronous only when unpaused. Cancel/pause inside the callback
    // wins before this permit; no chunk is acknowledged merely for queuing.
    if (!_stopping &&
        !_failed &&
        !_controller.isPaused &&
        _controller.hasListener &&
        _needsPermit &&
        _delivered) {
      _needsPermit = false;
      _delivered = false;
      _api.setEvent(_permit);
    }
  }

  void _cancelRead() {
    if (!_eligible) return;
    _api.cancel(_input, Pointer<_Overlapped>.fromAddress(_overlapped!));
    _api.cancelSync(_thread!);
  }

  void _fail() {
    _failed = true;
    _pending = null;
    _needsPermit = false;
    // Retain the error for the listener. Only explicit consumer cancellation
    // may convert termination into a quiet close.
    _requestStop();
  }

  void _requestStop() {
    _api.setEvent(_stop);
    _cancelRead();
    if (_eligible) {
      _retry ??= Timer.periodic(const Duration(milliseconds: 10), (_) {
        _cancelRead();
      });
    }
  }

  Future<void> close() {
    if (_stopping || _done.isCompleted) return _done.future;
    _stopping = true;
    _pending = null;
    if (!_started) {
      _spawnSettled = true;
      _workerExited = true;
      _finish();
    } else {
      _requestStop();
    }
    return _done.future;
  }

  void _finish() {
    if (!_workerExited || !_spawnSettled || _done.isCompleted) return;
    if (_started && !_settled) _failed = true;
    final reportFailure = !_stopping && _failed;
    _stopping = true;
    _eligible = false;
    _retry?.cancel();
    for (final event in [_stop, _permit, _release]) {
      _api.closeHandle(event);
    }
    _messages.close();
    _exit.close();
    _errors.close();
    if (reportFailure) {
      _controller.addError(StateError('pipe input unavailable'));
    }
    if (!_controller.isClosed) unawaited(_controller.close());
    _done.complete();
  }
}

// No await, yield, callback, or asynchronous scheduling in this worker turn.
// Keep the exact executing thread reserved until parent revokes cancellation.
void _readPipe(List<Object> arguments) {
  final parent = arguments[0] as SendPort;
  final input = arguments[1] as int;
  final stop = arguments[2] as int;
  final permit = arguments[3] as int;
  final release = arguments[4] as int;
  final api = _PipeApi();
  final readRegistrationEventForTesting = arguments[5] as int;
  var boundaryObserved = false;
  Pointer<Uint8> buffer = nullptr;
  Pointer<Uint32> count = nullptr;
  Pointer<_Overlapped> overlapped = nullptr;
  Pointer<IntPtr> thread = nullptr;
  Pointer<IntPtr> events = nullptr;
  var ioEvent = 0;
  var published = false;
  var failed = false;
  try {
    buffer = calloc<Uint8>(_chunkBytes);
    count = calloc<Uint32>();
    overlapped = calloc<_Overlapped>();
    thread = calloc<IntPtr>();
    events = calloc<IntPtr>(2);
    ioEvent = api.event();
    overlapped.ref.event = ioEvent;
    events[0] = stop;
    events[1] = permit;
    final process = api.currentProcess();
    if (api.duplicate(process, api.currentThread(), process, thread, 0, 0, 2) ==
        0) {
      throw StateError('pipe thread unavailable');
    }
    parent.send(['ready', thread.value, overlapped.address]);
    published = true;
    while (true) {
      final ready = api.waitMany(2, events, 0, _infinite);
      if (ready == 0) break;
      if (ready != 1) throw StateError('pipe permit unavailable');
      if (api.wait(stop, 0) == 0) break;
      if (readRegistrationEventForTesting != 0 && !boundaryObserved) {
        boundaryObserved = true;
        parent.send(['read_boundary']);
        if (api.wait(readRegistrationEventForTesting, _infinite) != 0) {
          throw StateError('pipe read boundary unavailable');
        }
      }
      // Previous I/O is terminal before reinitializing its unique storage.
      overlapped.ref.internal = 0;
      overlapped.ref.internalHigh = 0;
      overlapped.ref.offset = 0;
      overlapped.ref.offsetHigh = 0;
      api.resetEvent(ioEvent);
      final error = api.readPipe(input, buffer, _chunkBytes, overlapped, count);
      if (api.wait(stop, 0) == 0) break;
      if (error != 0 && error != 234) {
        if (error == 109 || error == 232 || error == 233) break;
        throw StateError('pipe read unavailable');
      }
      if (count.value > _chunkBytes) {
        throw StateError('pipe read exceeded buffer');
      }
      // A zero-byte pipe write is not EOF. Read again with the same permit.
      if (count.value == 0) {
        api.setEvent(permit);
        continue;
      }
      parent.send([
        'chunk',
        Uint8List.fromList(buffer.asTypedList(count.value)),
      ]);
    }
  } catch (_) {
    failed = true;
  } finally {
    // The native bridge returns only after terminal I/O completion.
    parent.send(['settled', failed]);
    if (published) {
      // A failed wait cannot authorize thread reuse or storage release.
      while (api.wait(release, _infinite) != 0) {
        api.sleep(10);
      }
    }
    if (thread != nullptr && thread.value != 0) api.closeHandle(thread.value);
    if (ioEvent != 0) api.closeHandle(ioEvent);
    calloc.free(events);
    calloc.free(thread);
    calloc.free(overlapped);
    calloc.free(count);
    calloc.free(buffer);
  }
}

@Native<Uint32 Function()>(symbol: 'quotabot_pipe_input_abi')
external int _nativePipeAbi();

// Blocking reads must not be leaf calls: another isolate must remain able to
// cancel the exact operation and the VM must remain able to run GC.
@Native<
    Uint32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<_Overlapped>,
        Pointer<Uint32>)>(symbol: 'quotabot_read_pipe')
external int _nativeReadPipe(int input, Pointer<Uint8> buffer, int capacity,
    Pointer<_Overlapped> overlapped, Pointer<Uint32> transferred);

bool _usingWindowsPipeStdin = false;

/// Test diagnostics must not instantiate the SDK stdin socket in pipe mode.
bool get usingWindowsPipeStdin => _usingWindowsPipeStdin;

/// Leaves terminals, files, and every non-Windows input on the SDK path.
WindowsPipeInput? openWindowsPipeStdin() {
  if (!Platform.isWindows) return null;
  final kernel = DynamicLibrary.open('kernel32.dll');
  final handle =
      kernel.lookupFunction<IntPtr Function(Uint32), int Function(int)>(
          'GetStdHandle')(0xfffffff6);
  final type =
      kernel.lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
          'GetFileType')(handle);
  if (type != 3) return null;
  final input = WindowsPipeInput(handle);
  _usingWindowsPipeStdin = true;
  return input;
}

// The pinned SDK accepts Stdin, but only uses its stream interface. Keep the
// parser, bounded framing, subscription cancellation, and output queue intact.
final class _PipeStdin extends StreamView<List<int>> implements Stdin {
  _PipeStdin(super.stream);
  @override
  bool get hasTerminal => false;
  @override
  bool get supportsAnsiEscapes => false;
  Never _unsupported() => throw UnsupportedError('pipe stream input only');
  @override
  int readByteSync() => _unsupported();
  @override
  String? readLineSync(
          {Encoding encoding = systemEncoding, bool retainNewlines = false}) =>
      _unsupported();
  @override
  bool get echoMode => _unsupported();
  @override
  set echoMode(bool value) => _unsupported();
  @override
  bool get echoNewlineMode => _unsupported();
  @override
  set echoNewlineMode(bool value) => _unsupported();
  @override
  bool get lineMode => _unsupported();
  @override
  set lineMode(bool value) => _unsupported();
}
