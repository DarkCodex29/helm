/// A folder the user nominated for downloads to be kept in.
///
/// [uri] is opaque and platform-owned. On Android it is a
/// `content://.../tree/...` string minted by the Storage Access Framework,
/// and it is a CAPABILITY HANDLE rather than a path: what makes it usable
/// is a grant recorded in the system's permission table, not anything in
/// the string. That has two consequences this feature is built around —
/// the string can never be constructed, only received from the picker, and
/// it can stop working while staying byte-identical, because the grant
/// behind it is what the user (or a data wipe) takes away.
///
/// [name] is the folder's display name and exists ONLY to be shown. It is
/// never used to locate anything: two folders can share a name, and the
/// picker returns the leaf name rather than a path, so `Documents` may well
/// be several levels down from anywhere the user would call Documents.
class DownloadDestination {
  const DownloadDestination({required this.uri, required this.name});

  final String uri;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is DownloadDestination && other.uri == uri && other.name == name;

  @override
  int get hashCode => Object.hash(uri, name);

  @override
  String toString() => 'DownloadDestination($name, $uri)';
}

/// What happened to a download AFTER its bytes were safely on the device.
///
/// A separate hierarchy from [DownloadOutcome], and keeping the two apart
/// is the entire point of this file. PUBLISHING IS NOT THE DOWNLOAD: by
/// the time any of these values exists the transfer has already completed
/// and passed its length check, so the file is on the device and openable
/// no matter which one comes back. Folding a publish failure into
/// [DownloadFailed] would tell the user their download failed while they
/// are looking at bytes that arrived intact.
///
/// Four cases rather than success-or-error, because three genuinely
/// different things all mean "nothing was copied" and the user is owed a
/// different answer to each: nowhere was chosen, nowhere needed choosing,
/// or somewhere was chosen and no longer works.
sealed class PublishOutcome {
  const PublishOutcome();
}

/// The file was copied into the folder the user chose.
final class PublishedToFolder extends PublishOutcome {
  const PublishedToFolder({
    required this.folderName,
    required this.fileName,
    required this.uri,
  });

  /// The destination folder's display name, for saying where it went.
  final String folderName;

  /// The name the file ACTUALLY ended up with, which is not always the
  /// name it was asked to have.
  ///
  /// Two platform behaviours can rename it, and both are silent:
  /// `DocumentFile.createFile` appends an extension when the MIME type
  /// disagrees with the one in the name, and a collision under
  /// [DocumentTreeGateway.copyInto]'s no-overwrite contract mints
  /// `report(1).docx`. Reporting the real name is what keeps either from
  /// leaving the user hunting for a file that is not called what the app
  /// said it was.
  final String fileName;

  /// Where it landed, for anything that later needs to address it.
  final Uri uri;
}

/// No folder has been chosen, so nothing was copied.
///
/// NOT a failure and never rendered as one. The download worked; the user
/// simply has not told this app where they want files kept, which is a
/// question that has never been asked at the point this first occurs.
final class PublishNotConfigured extends PublishOutcome {
  const PublishNotConfigured();
}

/// This platform already stores downloads somewhere the user can reach, so
/// there is nothing to copy.
///
/// iOS, in practice. `Documents/helm_downloads` is published to the Files
/// app by `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`
/// (see [SftpDownloadService.defaultDownloadDirectory]), so the file is
/// already visible to the user and to other apps the moment it is written.
///
/// Distinct from [PublishNotConfigured] on purpose. Both mean "no copy
/// happened", and the reasons are opposites: one is an unanswered
/// question, the other is a question that does not apply. Offering an iOS
/// user a folder picker to resolve the first would be offering to fix
/// something that is not broken.
final class PublishNotNeeded extends PublishOutcome {
  const PublishNotNeeded();
}

/// A folder was chosen, and the file could not be put in it.
final class PublishFailed extends PublishOutcome {
  const PublishFailed(this.reason, {this.detail});

  final PublishFailure reason;

  /// The underlying message, for the log. Never user-facing copy — the
  /// presentation layer writes those from [reason] alone, matching
  /// [DownloadFailed.detail].
  final String? detail;
}

/// Why publishing failed.
enum PublishFailure {
  /// The persisted grant on the chosen folder is gone.
  ///
  /// A grant survives reboots and app updates but not everything: the user
  /// can revoke it in system settings, clearing app data drops it, and on
  /// some devices a storage volume being remounted invalidates it. The
  /// stored folder is forgotten when this happens, because a URI whose
  /// grant is gone names nothing this app can use and keeping it would
  /// only let the UI claim a destination it cannot write to.
  permissionLost,

  /// The grant is intact and the folder itself is no longer there.
  ///
  /// Told apart from [permissionLost] rather than merged into it, even
  /// though both end with the user picking again, because the two suggest
  /// different next moves: a revoked grant can be restored by choosing the
  /// same folder, a deleted one cannot.
  destinationMissing,

  /// The copy started and did not finish: no room, or the provider
  /// refused the write.
  storage,

  /// Something else went wrong.
  unknown,
}
