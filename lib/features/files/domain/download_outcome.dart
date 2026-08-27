import 'dart:io';

/// How a download ENDED.
///
/// A sealed hierarchy rather than a nullable [File] plus an error string,
/// for the same reason [RemoteListing] is one: the three endings are not
/// degrees of the same thing, and the pair this feature most needs to keep
/// apart is [DownloadCompleted] and [DownloadCancelled].
///
/// That pair is the whole reason this type exists. dartssh2 offers no
/// cancellation on the read path at all — `abort()` lives on
/// [SftpFileWriter] (`sftp_stream_io.dart:74`), the UPLOAD half, and there
/// is no equivalent on [SftpFile]. So cancelling here means this app stops
/// consuming the stream, and a stopped consumer looks exactly like a
/// finished one unless something records WHY it stopped. This type is that
/// record: a cancelled transfer can never be spelled [DownloadCompleted],
/// because it is a different class.
sealed class DownloadOutcome {
  const DownloadOutcome();
}

/// Every byte arrived, the count matched what the server declared, and the
/// bytes are at [file].
///
/// [file] is the FINAL path. It is only ever reached by renaming a
/// fully-written partial file, so a path carried by this class always
/// holds a complete download — see [SftpDownloadService.download].
final class DownloadCompleted extends DownloadOutcome {
  const DownloadCompleted(this.file, {required this.bytes});

  final File file;

  /// Bytes written, which by construction equals the size the server
  /// reported for the open handle.
  final int bytes;
}

/// The user stopped it. NOT a failure, and never reported as one.
///
/// Carries nothing: the partial bytes are deleted before this is
/// returned, so there is no file to name and no progress worth keeping.
final class DownloadCancelled extends DownloadOutcome {
  const DownloadCancelled();
}

/// It stopped for a reason nobody asked for.
final class DownloadFailed extends DownloadOutcome {
  const DownloadFailed(this.reason, {this.detail});

  final DownloadFailure reason;

  /// The underlying message, for the log. Never the user-facing string —
  /// the presentation layer writes those from [reason] alone, so a server
  /// message can never become UI copy.
  final String? detail;
}

/// Why a download failed.
///
/// [sizeMismatch] and [stalled] are the two that describe THIS app's
/// checks rather than the server's answer, and both are deliberate: see
/// [SftpDownloadService.download] for what each one is defending against.
enum DownloadFailure {
  /// The server refused to open the file.
  permissionDenied,

  /// The file was gone by the time the transfer opened it.
  notFound,

  /// The transport died: channel closed, client aborted, socket gone.
  disconnected,

  /// No bytes arrived for [SftpDownloadService.idleTimeout].
  ///
  /// NOT "the download took too long". A transfer that is slow but still
  /// moving never reaches this, however long it runs.
  stalled,

  /// The server would not say how big the file is.
  ///
  /// `SftpFileAttrs.size` is optional in the protocol
  /// (`sftp_file_attrs.dart`), and every other guard in the transfer —
  /// progress percentage, the completeness check — is computed FROM that
  /// size. Guessing one would make all of them lies, so the transfer
  /// refuses instead.
  unknownSize,

  /// The byte count did not match the size the server declared.
  sizeMismatch,

  /// The device could not store the file: no space, no permission, or the
  /// rename into place failed.
  storage,

  /// Something else went wrong.
  unknown,
}
