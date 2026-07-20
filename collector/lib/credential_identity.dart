const opaqueCredentialIdentityPrefix = 'credential:';

final _opaqueCredentialIdentityPattern = RegExp(
  r'^credential:[0-9a-f]{64}$',
);

/// True only for the full opaque credential identity format. Truncated digests
/// are display labels only and must never become cache or filter identities.
bool isOpaqueCredentialIdentity(String? value) =>
    value != null && _opaqueCredentialIdentityPattern.hasMatch(value);

/// Human-safe label for an account identity. Machine-readable output and exact
/// matching must continue to use the original value.
String quotaAccountDisplayLabel(String account) {
  if (!isOpaqueCredentialIdentity(account)) return account;
  final digest = account.substring(opaqueCredentialIdentityPrefix.length);
  return 'account ${digest.substring(0, 8)}';
}
