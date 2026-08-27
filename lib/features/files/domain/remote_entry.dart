import 'package:freezed_annotation/freezed_annotation.dart';

part 'remote_entry.freezed.dart';

/// What one directory entry IS, resolved once when the listing is mapped.
///
/// Four values, not the nine `SftpFileType` carries, because that is the
/// number this app can act on: you can open a directory, you might one day
/// download a file, a symlink needs its target resolved before either
/// applies, and everything else — sockets, pipes, devices — is something
/// the browser can name but never enter.
enum RemoteEntryKind {
  /// A directory. The only kind that is unconditionally navigable.
  directory,

  /// A regular file.
  file,

  /// A symbolic link. See [RemoteEntry.linkTarget] for what it points at,
  /// which is a separate question and a separate round-trip.
  symlink,

  /// A socket, pipe, device, whiteout — or a type the server described in
  /// a way this app could not read.
  ///
  /// Notably this is also where an entry lands when the server sent no
  /// permissions AND no usable `longname`. That is deliberate: labelling
  /// an unreadable description as [file] would be a fabricated answer, and
  /// files are the one kind a future slice will offer to download.
  other,
}

/// One entry in a remote directory listing.
///
/// Every dartssh2 type has already been resolved away by the time one of
/// these exists — see `sftp_entry_mapper.dart`. The presentation layer
/// never imports `package:dartssh2`.
@freezed
class RemoteEntry with _$RemoteEntry {
  const factory RemoteEntry({
    /// The entry's own name, with no path in it.
    required String name,

    /// The absolute path of this entry on the remote host.
    required String path,

    required RemoteEntryKind kind,

    /// For a [RemoteEntryKind.symlink], what the link resolves to.
    ///
    /// Null means "not a symlink, or the target could not be resolved" —
    /// a broken link, or one pointing somewhere the session may not stat.
    /// It is NOT a claim that the target is a file.
    RemoteEntryKind? linkTarget,

    /// Size in bytes, or null when the server omitted it.
    ///
    /// Nullable rather than zero-defaulted: every field of
    /// `SftpFileAttrs` is optional in the protocol
    /// (`sftp_file_attrs.dart:157-187`), and a real zero-byte file must
    /// stay distinguishable from a server that simply did not say.
    int? size,

    /// Last modification time, or null when the server omitted it.
    DateTime? modifiedAt,

    /// Whether this entry is readable — with null meaning "the server did
    /// not give us enough to answer".
    ///
    /// Three-valued ON PURPOSE, and this is the field most likely to look
    /// like an oversight. SFTP reports permission BITS but not whether the
    /// authenticated user owns the file: the `uid`/`gid` in
    /// `SftpFileAttrs` are the FILE's, and the protocol never sends the
    /// session's own. So a mode of `0600` is genuinely unanswerable — it
    /// is readable if we are the owner and refused if we are not, and
    /// nothing on the wire says which.
    ///
    /// Only the two ownership-independent cases are ever asserted: every
    /// read bit set (true), or none set (false). A bool would have forced
    /// one of those guesses onto the middle case, and this codebase does
    /// not represent "unknown" as a definite answer — see
    /// [HostReportStatus.truncated], which exists for the same reason.
    bool? isReadable,
  }) = _RemoteEntry;

  const RemoteEntry._();

  /// Whether tapping this entry should open it as a directory.
  ///
  /// A symlink counts only once its target has been resolved to a
  /// directory. An unresolved link is not navigable, which is the honest
  /// outcome: entering it would fail at the server anyway, and failing on
  /// a tap is worse than not offering the tap.
  bool get isNavigable =>
      kind == RemoteEntryKind.directory ||
      (kind == RemoteEntryKind.symlink &&
          linkTarget == RemoteEntryKind.directory);

  /// Whether tapping this entry should download it.
  ///
  /// The exact complement of [isNavigable] over the kinds this app acts
  /// on, and built the same way: a symlink qualifies only once its target
  /// has been RESOLVED to a regular file.
  ///
  /// [RemoteEntryKind.other] is excluded on purpose, and that exclusion is
  /// the reason that kind exists. It covers sockets, pipes and devices —
  /// which have no length to download and would hang or fail a read — but
  /// ALSO an entry the server described in a way this app could not read.
  /// Offering to download the second group would mean guessing that an
  /// undescribed entry is a file, which is precisely the fabricated answer
  /// [RemoteEntryKind.other] was introduced to avoid.
  bool get isDownloadable =>
      kind == RemoteEntryKind.file ||
      (kind == RemoteEntryKind.symlink && linkTarget == RemoteEntryKind.file);
}
