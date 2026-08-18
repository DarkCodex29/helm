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

  /// Prefix for trusted host key fingerprints. The full key is
  /// `helm_known_host_<host>:<port>`, so the same hostname reached on a
  /// different port is trusted independently.
  static const String knownHostStorageKeyPrefix = 'helm_known_host_';
  static const String profilesStorageKey = 'helm_connection_profiles';
  static const String sessionDirtyKey = 'helm_session_dirty';
  static const String sessionSnapshotKey = 'helm_session_snapshot';

  static const int defaultTerminalColumns = 80;
  static const int defaultTerminalRows = 24;
}
