class AppConstants {
  AppConstants._();

  static const String appName = 'Helm';
  static const String appVersion = '0.1.0';

  static const int defaultSshPort = 22;
  static const String defaultSessionRef = 'helm';
  static const int maxReconnectAttempts = 3;
  static const List<int> reconnectDelays = [1, 3, 5];

  static const String sshPrivateKeyStorageKey = 'helm_ssh_private_key';
  static const String sshPublicKeyStorageKey = 'helm_ssh_public_key';

  /// Prefix for the SUPERSEDED host key trust entries, whose full key is
  /// `helm_known_host_<host>:<port>`.
  ///
  /// Nothing is written here any more. It is still read, and only for one
  /// purpose: an entry under this prefix with no counterpart under
  /// [knownHostV2StorageKeyPrefix] is how `KnownHostsService` recognises a
  /// host pinned before helm changed what it stores. Those values are
  /// `SHA256(MD5(host key))` — see `KnownHostsService.decodeFingerprint` —
  /// and cannot be compared against anything a current build computes, so
  /// they are treated as a re-authorization prompt rather than as a
  /// fingerprint.
  ///
  /// Deleted, never overwritten, once the user accepts the migration.
  static const String knownHostStorageKeyPrefix = 'helm_known_host_';

  /// Prefix for current host key trust entries. The full key is
  /// `helm_known_host_v2_<host>:<port>:<keyType>`.
  ///
  /// Two things changed from [knownHostStorageKeyPrefix], and both are
  /// load-bearing:
  ///
  /// * The `v2` segment. Old and new values are shape-indistinguishable —
  ///   both render as `SHA256:<base64>` — so the storage key is the only
  ///   sound way to tell a pin helm can verify from one it cannot.
  /// * The `<keyType>` segment. A server offers several host keys and the
  ///   client picks one by preference order; dartssh2 3.3.1 moved
  ///   `ssh-rsa` from fourth to last in that order, so a host that used to
  ///   negotiate RSA can now negotiate ECDSA. That is a genuinely
  ///   different key, not an impersonation, and without the key type here
  ///   helm could not tell the two apart — such a host would alternate
  ///   between "mismatch" and "re-pinned" forever.
  ///
  /// Key types come from dartssh2's closed `SSHHostkeyType` set
  /// (`ssh-ed25519`, `rsa-sha2-512`, `rsa-sha2-256`, `ecdsa-sha2-nistp521`,
  /// `ecdsa-sha2-nistp384`, `ecdsa-sha2-nistp256`, `ssh-rsa`). None of them
  /// contains a colon and a port is always digits, so no two distinct
  /// host/port/type triples can produce the same key.
  static const String knownHostV2StorageKeyPrefix = 'helm_known_host_v2_';
  static const String profilesStorageKey = 'helm_connection_profiles';
  static const String sessionDirtyKey = 'helm_session_dirty';
  static const String sessionSnapshotKey = 'helm_session_snapshot';

  static const int defaultTerminalColumns = 80;
  static const int defaultTerminalRows = 24;
}
