/// Outcomes for the three remote-write operations this slice adds: create
/// a directory, rename an entry, delete an entry.
///
/// Three sealed hierarchies rather than one shared result type.
/// [MkdirOutcome], [RenameOutcome] and [DeleteOutcome] each name failures
/// that only make sense for the call that can produce them — a destination
/// that already exists has no equivalent in a delete, a non-empty
/// directory has none in a mkdir — and collapsing them into one type would
/// leave every caller handling cases its own call could never reach. Same
/// reasoning as [RemoteListing] versus [DownloadOutcome]: distinct
/// questions get distinct answer types.
library;

/// A name rejected before any round trip to the server.
///
/// Everything here is answerable from the string alone. That is the whole
/// reason this check happens locally rather than being left to a server
/// refusal: a round trip costs time and tells the user nothing a local
/// check could not have said instantly, and a flaky connection must not
/// get a vote on whether "my/name" is a legal entry name.
enum NameRejection {
  /// The name is empty once trimmed.
  empty,

  /// The name contains a `/`, which would make it a path rather than a
  /// single entry of the current directory.
  containsSeparator,

  /// The name is exactly `.`.
  currentDirectory,

  /// The name is exactly `..`.
  parentDirectory,
}

/// Rejects [name] for any reason [NameRejection] can name, or returns null
/// when it is fit to send to the server.
///
/// Trimmed before every check: a name of all whitespace is
/// indistinguishable from empty once it reaches a directory listing, and a
/// trailing space a keyboard added by accident should not become a hidden
/// difference between what the user typed and what the server stores.
NameRejection? validateRemoteName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return NameRejection.empty;
  if (trimmed.contains('/')) return NameRejection.containsSeparator;
  if (trimmed == '.') return NameRejection.currentDirectory;
  if (trimmed == '..') return NameRejection.parentDirectory;
  return null;
}

/// Why a write that passed name validation was still refused by the
/// transport.
///
/// Mirrors [RemoteListingFailure] exactly, and for the same reason: a read
/// and a write travel the same `SftpStatusError` vocabulary, so
/// [SftpFileService] classifies both from identical wire evidence.
enum RemoteWriteFailure {
  /// `SSH_FX_PERMISSION_DENIED`.
  permissionDenied,

  /// `SSH_FX_NO_SUCH_FILE`. The entry this write targeted is gone.
  notFound,

  /// The SFTP channel itself is no longer usable.
  disconnected,

  /// The server refused for a reason it did not classify.
  unknown,
}

/// The outcome of asking the server to create one directory.
sealed class MkdirOutcome {
  const MkdirOutcome();
}

/// The directory now exists at [path].
final class MkdirCreated extends MkdirOutcome {
  const MkdirCreated(this.path);
  final String path;
}

/// The requested name was rejected before anything was sent to the server.
final class MkdirInvalidName extends MkdirOutcome {
  const MkdirInvalidName(this.reason);
  final NameRejection reason;
}

/// Something already answers to this path.
///
/// Reached by a `stat` BEFORE `mkdir` is ever called, not by reading the
/// server's refusal: SFTP v3 has no status code for "already exists" —
/// [RemoteWriteFailure] carries none, the same absence
/// `RemoteListingFailure` documents for `notADirectory` — so OpenSSH
/// answers the generic `SSH_FX_FAILURE` for this exact case, the same code
/// it uses for a dozen unrelated refusals. Checking first is the only way
/// this outcome can exist as its own thing rather than folding into
/// [MkdirFailed.unknown].
final class MkdirAlreadyExists extends MkdirOutcome {
  const MkdirAlreadyExists();
}

final class MkdirFailed extends MkdirOutcome {
  const MkdirFailed(this.reason, {this.detail = ''});
  final RemoteWriteFailure reason;
  final String detail;
}

/// The outcome of asking the server to rename or move one entry.
sealed class RenameOutcome {
  const RenameOutcome();
}

/// The entry now lives at [path].
final class RenameCompleted extends RenameOutcome {
  const RenameCompleted(this.path);
  final String path;
}

final class RenameInvalidName extends RenameOutcome {
  const RenameInvalidName(this.reason);
  final NameRejection reason;
}

/// The new name is byte-identical to the current one.
///
/// Not a [NameRejection]: the string is a perfectly legal entry name, just
/// pointless to send — a rename to the same name would either no-op on the
/// wire or, on a server with `posix-rename@openssh.com`, replace the entry
/// with itself for no reason.
final class RenameUnchanged extends RenameOutcome {
  const RenameUnchanged();
}

/// Something already answers to the destination name.
///
/// This check is the entire reason a rename stats before it renames.
/// `SftpClient.rename` silently picks between two incompatible behaviours
/// depending on what the server advertises (`sftp_client.dart:191-216`,
/// verified against dartssh2 3.3.1): a server offering the
/// `posix-rename@openssh.com` extension OVERWRITES the destination
/// atomically, while a server without it falls back to the standard
/// `SSH_FXP_RENAME`, which FAILS when the destination exists. Calling
/// `rename` without checking first would make this app's behaviour toward
/// data already at the destination a property of which server it happens
/// to be talking to — decided by the library, never by this app. Stat-ing
/// the destination first and refusing whenever something is already there
/// makes the behaviour IDENTICAL on every server: never overwrite,
/// regardless of what the library underneath would otherwise have chosen.
final class RenameDestinationExists extends RenameOutcome {
  const RenameDestinationExists();
}

final class RenameFailed extends RenameOutcome {
  const RenameFailed(this.reason, {this.detail = ''});
  final RemoteWriteFailure reason;
  final String detail;
}

/// The outcome of asking the server to delete one entry.
sealed class DeleteOutcome {
  const DeleteOutcome();
}

final class DeleteCompleted extends DeleteOutcome {
  const DeleteCompleted();
}

/// The directory held something besides itself and its parent.
///
/// Helm refuses to delete a non-empty directory in this slice rather than
/// walking it and deleting its contents first. SFTP's own `rmdir` already
/// refuses a non-empty directory (`sftp_client.dart:173-179`), so checked
/// FIRST here only to report the real reason: the server's refusal is the
/// generic `SSH_FX_FAILURE`, indistinguishable on the wire from causes that
/// have nothing to do with the directory's contents. Recursive deletion is
/// deliberately NOT offered — a mobile file browser has no undo, no
/// trash, and no way to show the user everything that is about to
/// disappear beneath one tap. The user must empty the directory from
/// somewhere that can show them what they are removing, then come back to
/// delete the now-empty directory.
final class DeleteDirectoryNotEmpty extends DeleteOutcome {
  const DeleteDirectoryNotEmpty();
}

final class DeleteFailed extends DeleteOutcome {
  const DeleteFailed(this.reason, {this.detail = ''});
  final RemoteWriteFailure reason;
  final String detail;
}
