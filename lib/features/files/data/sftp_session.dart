import 'package:dartssh2/dartssh2.dart';

/// The subset of an open SFTP session that [SftpFileService] needs to
/// browse a remote filesystem.
///
/// [SftpClient] cannot be constructed outside dartssh2 — its only
/// constructor takes an [SSHChannel], which in turn requires a live
/// transport — so this interface is the seam tests use to avoid a real
/// connection. [_SftpClientSession] adapts a real [SftpClient] to it in
/// production.
///
/// Exactly the same shape as `SshCommandChannel`
/// (`lib/core/host/ssh_host_command_runner.dart:14`), and for the same
/// reason. Deliberately NOT a re-typed DTO layer: the dartssh2 reply types
/// ([SftpName], [SftpFileAttrs]) cross this boundary as they are, because
/// both have public constructors, so a fake can build a reply that is
/// byte-identical in shape to a server's. Translating them here instead
/// would put the mapping that most needs testing — see
/// `sftp_entry_mapper.dart` — on the untestable side of the seam.
abstract interface class SftpSession {
  /// Reads every entry of the directory at [path].
  ///
  /// [SftpClient.listdir] rather than [SftpClient.readdir], and that is
  /// not a style preference. `readdir` is an `async*` generator whose
  /// `await _close(dir)` sits after the loop rather than in a `finally`
  /// (`sftp_client.dart:137-145`), so a consumer that cancels the stream
  /// early leaves the remote directory handle open — still true in 3.3.1,
  /// verified by reading that source. `listdir` always drains, so it
  /// cannot leak that way.
  Future<List<SftpName>> listdir(String path);

  /// Reads the attributes of [path], following symlinks by default.
  Future<SftpFileAttrs> stat(String path, {bool followLink = true});

  /// Resolves [path] to an absolute path on the server.
  Future<String> absolute(String path);

  /// Ends the session and the SSH channel underneath it.
  Future<void> close();
}

/// Opens an SFTP session over a live transport.
typedef SftpSessionOpener = Future<SftpSession> Function();

/// Adapts a real [SftpClient] to [SftpSession].
class SftpClientSession implements SftpSession {
  SftpClientSession(this._client);

  final SftpClient _client;

  @override
  Future<List<SftpName>> listdir(String path) => _client.listdir(path);

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) =>
      _client.stat(path, followLink: followLink);

  @override
  Future<String> absolute(String path) => _client.absolute(path);

  /// Closes the SFTP session AND its channel.
  ///
  /// In dartssh2 2.16.0 this was a `void` that left the channel open, so
  /// every open/close cycle leaked one channel until the server refused
  /// further `CHANNEL_OPEN`s. 3.3.1 fixed it: `close()` returns a
  /// `Future<void>`, awaits `_channel.close()`, and is idempotent through
  /// a cached `_closeFuture` (`sftp_client.dart:254-266`). Awaiting it is
  /// therefore both meaningful and safe to repeat.
  @override
  Future<void> close() => _client.close();
}
