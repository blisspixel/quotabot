import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:quotabot_collector/src/io/windows_pipe_input.dart';

Future<void> main(List<String> arguments) async {
  final mode = arguments.first;
  final api = _FixtureApi();
  final handle = api.getStdHandle(0xfffffff6);
  final boundary = mode == 'registration_race' ? api.event() : 0;
  final failPending = Completer<void>();
  late WindowsPipeInput input;
  late StreamSubscription<List<int>> subscription;
  input = WindowsPipeInput(
    handle,
    readRegistrationEventForTesting: boundary,
    onReadRegistrationForTesting: mode == 'registration_race'
        ? () {
            // The first cancellation occurs before native read registration.
            unawaited(input.close());
            Timer(
              const Duration(milliseconds: 25),
              () => api.setEvent(boundary),
            );
          }
        : null,
    onPendingChunkForTesting: mode == 'startup_pending_failure'
        ? () {
            subscription.pause();
            failPending.complete();
            Timer(const Duration(milliseconds: 25), subscription.resume);
          }
        : null,
    startBoundaryForTesting: mode == 'late_start'
        ? (start) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await start();
          }
        : mode == 'startup_pending_failure'
            ? (start) async {
                await start();
                await failPending.future;
                throw StateError('synthetic pending-delivery failure');
              }
            : mode == 'startup_failure'
                ? (start) =>
                    Future<void>.error(StateError('synthetic start failure'))
                : mode == 'startup_after_launch_failure'
                    ? (start) async {
                        await start();
                        throw StateError('synthetic post-spawn failure');
                      }
                    : null,
  );
  if (mode == 'close_before_listen') {
    await input.close().timeout(const Duration(seconds: 3));
    await input.stream.drain<void>().timeout(const Duration(seconds: 3));
    stderr.writeln('settled');
    return;
  }
  var delivered = 0;
  var sawError = false;
  final observed = Completer<void>();
  subscription = input.stream.listen(
    (chunk) {
      for (var index = 0; index < chunk.length; index++) {
        if (chunk[index] != (delivered + index) % 251) {
          throw StateError('pipe delivery changed byte order');
        }
      }
      final first = delivered == 0;
      delivered += chunk.length;
      if (mode == 'cancel_delivery') {
        unawaited(subscription.cancel());
      } else if (mode == 'pause' && first) {
        subscription.pause();
        Timer(const Duration(milliseconds: 25), () {
          if (delivered != chunk.length) {
            throw StateError('delivery advanced while paused');
          }
          subscription.resume();
        });
      }
      if (mode == 'pause' && delivered == 256 * 1024) {
        unawaited(subscription.cancel());
      }
    },
    onError: (Object error) {
      sawError = true;
      if (!mode.startsWith('startup_')) {
        throw StateError('unexpected pipe error');
      }
    },
    onDone: () {
      if (!observed.isCompleted) observed.complete();
    },
  );
  if (mode == 'cancel_empty') {
    Timer(
      Duration(milliseconds: [0, 1, 2, 5, 25][int.parse(arguments[1]) % 5]),
      () {
        unawaited(subscription.cancel());
      },
    );
  }
  if (mode == 'cancel_before_ready' || mode == 'late_start') {
    final closing = subscription.cancel();
    if (mode == 'late_start') {
      var timedOut = false;
      try {
        await closing.timeout(const Duration(milliseconds: 10));
      } on TimeoutException {
        timedOut = true;
      }
      if (!timedOut) throw StateError('late ownership released before startup');
    }
    await closing.timeout(const Duration(seconds: 3));
  }
  await input.done.timeout(const Duration(seconds: 3));
  if (boundary != 0) api.closeHandle(boundary);
  if (mode == 'eof') {
    await observed.future.timeout(const Duration(seconds: 3));
    if (delivered != 16384) throw StateError('EOF lost bytes');
  }
  if (mode.startsWith('startup_') && !sawError) {
    await observed.future.timeout(const Duration(seconds: 3));
  }
  if (mode == 'startup_pending_failure' && delivered != 0) {
    throw StateError('startup failure delivered retained bytes');
  }
  if (mode.startsWith('startup_') && !sawError) {
    throw StateError('startup failure became EOF');
  }
  stderr.writeln('settled');
}

final class _FixtureApi {
  final _kernel = DynamicLibrary.open('kernel32.dll');
  late final getStdHandle =
      _kernel.lookupFunction<IntPtr Function(Uint32), int Function(int)>(
          'GetStdHandle');
  late final setEvent = _kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetEvent');
  late final closeHandle = _kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  int event() {
    final create = _kernel.lookupFunction<
        IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Utf16>),
        int Function(Pointer<Void>, int, int, Pointer<Utf16>)>('CreateEventW');
    final event = create(nullptr, 1, 0, nullptr);
    if (event == 0) throw StateError('fixture event unavailable');
    return event;
  }
}
