import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// One remote file opened for reading.
///
/// A SECOND seam beside [SftpSession], and it has to be: [SftpFile]'s only
/// constructor takes the private handle bytes an `SSH_FXP_OPEN` reply
/// carried (`sftp_file.dart:10`), so a test cannot build one any more than
/// it can build an [SftpClient]. [SftpFileReadHandle] adapts a real one in
/// production.
///
/// Deliberately NARROWER than [SftpFile]: this interface still has no
/// `write`, `writeBytes`, or `setStat` on an OPEN HANDLE. The management
/// slice that added [SftpSession.mkdir], [SftpSession.rename] and
/// [SftpSession.remove] widened the SESSION seam, not this one — those
/// three operate on whole paths and never need an open file handle at all.
/// Streaming bytes INTO an open handle is still a future upload slice's
/// job, not something this one quietly started carrying.
abstract interface class SftpReadHandle {
  /// The attributes of the OPEN HANDLE, which is what makes this method
  /// worth having beside [SftpSession.stat].
  ///
  /// `SSH_FXP_FSTAT` against the handle, not `SSH_FXP_STAT` against the
  /// path: the size read here describes the bytes this download is
  /// actually reading, and cannot be a different file that took the same
  /// name between the listing and the transfer.
  Future<SftpFileAttrs> stat();

  /// Streams the file's bytes in offset order.
  ///
  /// Both pipeline knobs are REQUIRED rather than defaulted, and that is
  /// the point of restating them here. dartssh2's own defaults for the
  /// download path are `_kDownloadChunkSize` 64 KiB and
  /// `_kDownloadMaxPendingRequests` 128 (`sftp_client.dart:32-33`) — 8 MiB
  /// of file resident in memory before a single byte reaches the disk.
  /// Making them required means no call site can reach that by omission;
  /// see [SftpDownloadService.pipelineBytesInFlight] for what this app
  /// asks for instead.
  Stream<Uint8List> read({
    required int chunkSize,
    required int maxPendingRequests,
  });

  /// Closes the remote file handle.
  Future<void> close();
}

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

  /// Opens [path] for reading.
  ///
  /// The caller owns the returned handle and must close it, including on
  /// failure — a leaked handle stays open on the server until the whole
  /// session ends.
  Future<SftpReadHandle> openRead(String path);

  /// Creates a directory at [path].
  ///
  /// Throws `SSH_FX_FAILURE` — through an [SftpStatusError] — when
  /// something already answers to [path]. Callers that need to tell
  /// "already exists" apart from an unrelated refusal must `stat` first;
  /// see [MkdirAlreadyExists] for why that check cannot be done from this
  /// method's own throw.
  Future<void> mkdir(String path);

  /// Removes the FILE at [path].
  ///
  /// Fails against a directory — use [rmdir] for that. This split exists
  /// in the wire protocol itself (`SSH_FXP_REMOVE` versus
  /// `SSH_FXP_RMDIR`), not something this seam invented, which is exactly
  /// why [SftpFileService.delete] has to know which kind of entry it was
  /// asked to delete before it can choose a call.
  Future<void> remove(String path);

  /// Removes the EMPTY directory at [path].
  ///
  /// Fails when the directory holds anything besides itself and its
  /// parent. Helm never recurses past this failure — see
  /// [DeleteDirectoryNotEmpty] for why that refusal is a deliberate
  /// product decision, not a gap.
  Future<void> rmdir(String path);

  /// Renames or moves the entry at [oldPath] to [newPath].
  ///
  /// Whether this overwrites an existing [newPath] is NOT settled by this
  /// interface — it depends on whether the server advertises OpenSSH's
  /// `posix-rename@openssh.com` extension, which [SftpClientSession]
  /// cannot see from here and a fake cannot meaningfully fake. Callers
  /// that must never overwrite — this app's only caller — `stat` the
  /// destination themselves first; see [RenameDestinationExists].
  Future<void> rename(String oldPath, String newPath);

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

  @override
  Future<SftpReadHandle> openRead(String path) async =>
      SftpFileReadHandle(await _client.open(path));

  @override
  Future<void> mkdir(String path) => _client.mkdir(path);

  @override
  Future<void> remove(String path) => _client.remove(path);

  @override
  Future<void> rmdir(String path) => _client.rmdir(path);

  @override
  Future<void> rename(String oldPath, String newPath) =>
      _client.rename(oldPath, newPath);

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

/// Adapts a real [SftpFile] to [SftpReadHandle].
///
/// [SftpFile.read] rather than any of the three `download*` conveniences,
/// and the choice is load-bearing rather than stylistic:
///
///  * `downloadTo` and `SftpClient.download` take a [StreamSink] and pump
///    it themselves (`sftp_file.dart:250-261`), which puts the loop that
///    has to notice a stall, a cancellation and a byte count on the far
///    side of the library.
///  * `downloadToRandomAccess` writes chunks at their own offsets as they
///    land (`:410-411`), so a transfer abandoned midway leaves a file with
///    HOLES rather than a short prefix — bytes that would pass a
///    length check while missing their middle.
///
/// [read] hands back an offset-ORDERED stream (`:43`) and nothing else, so
/// this app keeps the loop and a partial file is always a true prefix.
class SftpFileReadHandle implements SftpReadHandle {
  SftpFileReadHandle(this._file);

  final SftpFile _file;

  @override
  Future<SftpFileAttrs> stat() => _file.stat();

  @override
  Stream<Uint8List> read({
    required int chunkSize,
    required int maxPendingRequests,
  }) =>
      _file.read(chunkSize: chunkSize, maxPendingRequests: maxPendingRequests);

  @override
  Future<void> close() => _file.close();
}
