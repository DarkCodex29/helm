import 'package:helm/features/files/domain/remote_entry.dart';

/// Why a directory could not be listed.
///
/// Only reasons the wire can actually distinguish are listed. There is no
/// `notADirectory`: SFTP v3 has no status code for it, and OpenSSH answers
/// `SSH_FX_FAILURE` — the same generic code it uses for a dozen unrelated
/// refusals (`sftp_status_code.dart:21`). Inventing the distinction would
/// mean showing the user a specific explanation this app cannot support.
enum RemoteListingFailure {
  /// `SSH_FX_PERMISSION_DENIED`. The session may not read this directory.
  permissionDenied,

  /// `SSH_FX_NO_SUCH_FILE`. The path is gone, or never existed.
  notFound,

  /// The SFTP channel itself is no longer usable: it closed under us, the
  /// connection dropped, or the session could not be opened at all.
  ///
  /// Distinct from the two above because those leave the channel healthy —
  /// they are answers, not breakages. See `SftpFileService`, which keeps
  /// its session on a status error and drops it on this one.
  disconnected,

  /// The server refused for a reason it did not classify.
  unknown,
}

/// The outcome of asking for one directory's contents.
///
/// Sealed so that "it worked and there was nothing there" and "it did not
/// work" cannot be collapsed into the same empty list. That collapse is
/// the specific defect this codebase keeps designing against — see
/// [HostReportStatus.truncated] ("never treated as no sessions") and
/// `MuxWorkspaceTreeResult` — because an empty list reads as a fact about
/// the host when it is really a fact about the request.
sealed class RemoteListing {
  const RemoteListing();
}

/// The directory was read. [entries] may be empty, and an empty [entries]
/// is a POSITIVE claim: this directory has nothing in it.
final class RemoteListingLoaded extends RemoteListing {
  const RemoteListingLoaded(this.entries);

  final List<RemoteEntry> entries;
}

/// The directory was not read, and nothing is known about its contents.
final class RemoteListingFailed extends RemoteListing {
  const RemoteListingFailed(this.reason, {this.detail = ''});

  final RemoteListingFailure reason;

  /// The server's own words, when it sent any.
  ///
  /// Kept beside [reason] rather than shown in place of it: server
  /// messages are unlocalized, sometimes empty, and occasionally leak
  /// paths. The UI leads with [reason] and treats this as supporting
  /// detail.
  final String detail;
}
