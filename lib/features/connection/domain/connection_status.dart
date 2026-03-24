/// Represents the lifecycle state of an SSH connection.
enum ConnectionStatus {
  /// No active connection and no attempt in progress.
  disconnected,

  /// Connection attempt is underway.
  connecting,

  /// SSH session established and shell is open.
  connected,

  /// Connection failed or was lost unexpectedly.
  error,
}
