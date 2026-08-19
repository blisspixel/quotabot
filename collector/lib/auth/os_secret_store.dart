import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// `agy` / Antigravity CLI keyring coordinates used by zalando/go-keyring.
const agyKeyringService = 'gemini';
const agyKeyringAccount = 'antigravity';

/// Decodes a keyring blob as UTF-8, or as UTF-16LE when Windows stored a JSON
/// object as a wide string. Never used as a credential write path.
String? decodeOsSecretBytes(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  if (bytes.length >= 2 && bytes[0] == 0x7b && bytes[1] == 0) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

// Platform credential stores are I/O. Adapter tests inject parsed material
// instead of talking to Credential Manager, Keychain, or libsecret.
// coverage:ignore-start
String? readAgyOsKeyringSecret() =>
    readOsGenericSecret(agyKeyringService, agyKeyringAccount);

bool hasAgyOsKeyringSecret() {
  final secret = readAgyOsKeyringSecret();
  return secret != null && secret.isNotEmpty;
}

/// Reads a generic OS secret. Never writes. Returns null when the platform
/// store is missing, locked, or the named item is absent.
String? readOsGenericSecret(String service, String account) {
  if (service.isEmpty || account.isEmpty) return null;
  try {
    if (Platform.isWindows) {
      return _readWindowsGeneric('$service:$account');
    }
    if (Platform.isMacOS) {
      return _readMacOsGeneric(service, account);
    }
    if (Platform.isLinux) {
      return _readLinuxGeneric(service, account);
    }
  } catch (_) {
    return null;
  }
  return null;
}

String? _stdoutSecret(ProcessResult result) {
  if (result.exitCode != 0) return null;
  final stdout = result.stdout;
  if (stdout is! String) return null;
  final secret = stdout.trim();
  return secret.isEmpty ? null : secret;
}

String? _readMacOsGeneric(String service, String account) {
  return _stdoutSecret(
    Process.runSync(
      '/usr/bin/security',
      [
        'find-generic-password',
        '-s',
        service,
        '-a',
        account,
        '-w',
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ),
  );
}

String? _readLinuxGeneric(String service, String account) {
  for (final args in [
    ['lookup', 'service', service, 'username', account],
    ['lookup', 'service', service, 'account', account],
  ]) {
    try {
      final secret = _stdoutSecret(
        Process.runSync(
          'secret-tool',
          args,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ),
      );
      if (secret != null) return secret;
    } catch (_) {}
  }
  return null;
}

final class _WinCred extends Struct {
  @Uint32()
  external int flags;
  @Uint32()
  external int type;
  external Pointer<Utf16> targetName;
  external Pointer<Utf16> comment;
  @Uint32()
  external int lastWrittenLow;
  @Uint32()
  external int lastWrittenHigh;
  @Uint32()
  external int credentialBlobSize;
  external Pointer<Uint8> credentialBlob;
  @Uint32()
  external int persist;
  @Uint32()
  external int attributeCount;
  external Pointer<Void> attributes;
  external Pointer<Utf16> targetAlias;
  external Pointer<Utf16> userName;
}

typedef _CredReadNative = Int32 Function(
  Pointer<Utf16> target,
  Uint32 type,
  Uint32 flags,
  Pointer<Pointer<_WinCred>> credential,
);
typedef _CredReadDart = int Function(
  Pointer<Utf16> target,
  int type,
  int flags,
  Pointer<Pointer<_WinCred>> credential,
);
typedef _CredFreeNative = Void Function(Pointer<Void> credential);
typedef _CredFreeDart = void Function(Pointer<Void> credential);

const _credTypeGeneric = 1;

String? _readWindowsGeneric(String targetName) {
  final advapi = DynamicLibrary.open('advapi32.dll');
  final credRead =
      advapi.lookupFunction<_CredReadNative, _CredReadDart>('CredReadW');
  final credFree =
      advapi.lookupFunction<_CredFreeNative, _CredFreeDart>('CredFree');
  final target = targetName.toNativeUtf16();
  final credOut = calloc<Pointer<_WinCred>>();
  Pointer<Void> cred = nullptr;
  try {
    final ok = credRead(target, _credTypeGeneric, 0, credOut);
    if (ok == 0) return null;
    cred = credOut.value.cast();
    final parsed = cred.cast<_WinCred>().ref;
    final size = parsed.credentialBlobSize;
    if (size <= 0 || parsed.credentialBlob == nullptr) return null;
    final copy = Uint8List.fromList(parsed.credentialBlob.asTypedList(size));
    return decodeOsSecretBytes(copy);
  } finally {
    if (cred != nullptr) credFree(cred);
    calloc.free(target);
    calloc.free(credOut);
  }
}

// coverage:ignore-end
