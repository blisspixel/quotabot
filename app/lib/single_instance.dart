import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Cross-platform single-instance guard.
///
/// The desktop app closes to the tray instead of quitting, so launching it a
/// second time (from a shortcut, `flutter run`, or a relaunch) would create a
/// second process - and a second tray icon. This guard makes the first instance
/// the owner of a fixed loopback port; a later instance detects the owner, asks
/// it to surface its window, and exits before creating any window or tray icon.
///
/// It fails open: any unexpected error (port owned by unrelated software, IPC
/// hiccup) lets the current process start normally. A rare duplicate is far
/// better than a launch that silently never appears.
class SingleInstanceGuard {
  // An app-specific loopback port. Only used as an interprocess lock and a
  // "surface the window" doorbell - never as a network service.
  static const int _port = 47821;
  static const String _request = 'quotabot-single-instance-v1 show';
  static const String _ack = 'quotabot-single-instance-v1 ok';
  static const Duration _ipcTimeout = Duration(seconds: 2);

  ServerSocket? _server;

  /// Attempts to become the primary instance. Returns true when this process is
  /// the primary (and should continue starting up); false when another instance
  /// already owns the lock (and this process should exit without creating a
  /// window or tray icon). [onShowRequested] fires when a later instance asks
  /// the primary to surface its window.
  Future<bool> tryBecomePrimary({
    required Future<void> Function() onShowRequested,
  }) async {
    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _port);
    } on SocketException {
      // The port is taken. If a quotabot primary owns it, ring the doorbell and
      // step aside; otherwise (unrelated software) fail open and start normally.
      final surfaced = await _ringPrimaryDoorbell();
      return !surfaced;
    } catch (_) {
      // Any other bind failure: fail open rather than block startup.
      return true;
    }

    _server!.listen(
      (socket) => _handleDoorbell(socket, onShowRequested),
      onError: (_) {},
    );
    return true;
  }

  void _handleDoorbell(Socket socket, Future<void> Function() onShowRequested) {
    utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first
        .timeout(_ipcTimeout, onTimeout: () => '')
        .then((line) async {
          if (line.trim() == _request) {
            try {
              await onShowRequested();
            } catch (_) {}
            try {
              socket.write('$_ack\n');
              await socket.flush();
            } catch (_) {}
          }
        })
        .whenComplete(() {
          try {
            socket.destroy();
          } catch (_) {}
        })
        .catchError((_) {});
  }

  /// Connects to the presumed primary, asks it to surface, and confirms via the
  /// acknowledgement that it reached a real quotabot instance. Returns true only
  /// on a genuine ack - so a port held by unrelated software does not make this
  /// instance silently disappear.
  Future<bool> _ringPrimaryDoorbell() async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: _ipcTimeout,
      );
      socket.write('$_request\n');
      await socket.flush();
      final reply = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(_ipcTimeout, onTimeout: () => '');
      return reply.trim() == _ack;
    } catch (_) {
      return false;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
  }
}
