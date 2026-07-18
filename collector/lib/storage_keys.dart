import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Stable opaque identity for an exact provider account string.
///
/// Account names are provider-owned identifiers and can contain characters
/// that are unsafe in filenames. Replacing those characters is lossy, so local
/// storage uses the full SHA-256 digest instead. Provider ids remain readable
/// and canonical in every path.
String accountIdentityDigest(String account) =>
    sha256.convert(utf8.encode(account)).toString();

String accountStorageStem(String account) =>
    'account_${accountIdentityDigest(account)}';
