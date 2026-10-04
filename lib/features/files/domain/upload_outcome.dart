/// How an upload ENDED.
///
/// A sealed hierarchy for the same reason [DownloadOutcome] is one: the
/// pair this type exists to keep apart is [UploadCompleted] and
/// [UploadCancelled] — a transfer this app stopped feeding bytes looks,
/// from the outside, exactly like one that finished.
sealed class UploadOutcome {
  const UploadOutcome();
}

/// Every byte was sent, acknowledged, and the server holds it at [path]
/// — the FINAL destination, reached only by renaming a fully-written
/// partial, so a path here always names a complete upload.
final class UploadCompleted extends UploadOutcome {
  const UploadCompleted(this.path, {required this.bytes});

  /// The actual destination, which may differ from the requested path.
  final String path;

  /// The basename actually created on the host, not the requested name.
  String get name => path.substring(path.lastIndexOf('/') + 1);

  final int bytes;
}

/// The user stopped it. NOT a failure. The partial remote file is removed
/// before this is returned, so there is nothing left to name.
final class UploadCancelled extends UploadOutcome {
  const UploadCancelled();
}

/// All 100 candidate destination names were taken. Checked before reading
/// local bytes and again before finalizing; exhaustion at the latter check
/// discards the partial upload.
///
/// OpenSSH rename overwrites silently, so the service must check names
/// rather than rely on rename failing. These checks are not atomic with
/// rename: see [SftpUploadService.upload] for the remaining race.
final class UploadDestinationExists extends UploadOutcome {
  const UploadDestinationExists();
}

/// It stopped for a reason nobody asked for.
final class UploadFailed extends UploadOutcome {
  const UploadFailed(this.reason, {this.detail});

  final UploadFailure reason;

  /// For the log only — never the user-facing string.
  final String? detail;
}

/// Why an upload failed. [sourceUnreadable], [stalled] and [sizeMismatch]
/// describe THIS app's own checks, mirroring the split [DownloadFailure]
/// documents for its three analogous members.
enum UploadFailure {
  /// The server refused to open or write the file.
  permissionDenied,

  /// The destination's parent directory was gone when the transfer tried
  /// to create the partial file there.
  notFound,

  /// The transport died: channel closed, client aborted, socket gone.
  disconnected,

  /// The server stopped acknowledging writes for
  /// [SftpUploadService.idleTimeout]. NOT "took too long" — a transfer
  /// still being acknowledged never reaches this.
  stalled,

  /// The local file could not be read: missing, permission denied, or an
  /// I/O error partway through.
  sourceUnreadable,

  /// Bytes actually sent did not match the source's length as measured
  /// before the transfer started.
  sizeMismatch,

  /// Something else went wrong.
  unknown,
}
