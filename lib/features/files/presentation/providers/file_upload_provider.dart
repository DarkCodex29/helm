import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:helm/features/files/data/saf_upload_source.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
import 'package:helm/features/files/domain/upload_outcome.dart';

/// The live file picker for uploads.
///
/// A provider for the same reason
/// [downloadDestinationServiceProvider] is one: overridden wholesale in
/// tests, since [SafDocumentTreeGateway] reaches the platform over a
/// method channel a test host does not have.
final uploadSourcePickerProvider = Provider<UploadSourcePicker>(
  (_) => UploadSourcePicker(gateway: SafDocumentTreeGateway()),
);

// ── State ──────────────────────────────────────────────────────────────────

/// Where one upload is in its life.
///
/// FOUR terminal states rather than one generic failure, mirroring
/// [FileDownloadStatus]'s own split: [destinationExists] is kept apart
/// from [failed] because the user can ACT on it \u2014 pick a different file,
/// or rename the one on the host \u2014 and folding it into a generic failure
/// would hide that there is anything to do.
enum FileUploadStatus {
  /// Nothing is running and nothing needs acknowledging.
  idle,

  /// Bytes are moving. [FileUploadState.percent] is meaningful only here.
  uploading,

  /// Every byte arrived and the server holds it under [FileUploadState.name].
  completed,

  /// The user stopped it. NOT a failure.
  cancelled,

  /// Something already answers to the destination path. See
  /// [UploadDestinationExists] for why this is checked before a single
  /// local byte is read.
  destinationExists,

  /// It did not finish. [FileUploadState.failure] says why.
  failed,
}

@immutable
class FileUploadState {
  const FileUploadState({
    this.name,
    this.status = FileUploadStatus.idle,
    this.percent = 0,
    this.failure,
  });

  /// What is being, or was last, uploaded. Null only in [idle].
  final String? name;

  final FileUploadStatus status;

  /// Whole percent, 0-100. Updated only when the number CHANGES \u2014 the
  /// throttling happens in [SftpUploadService.upload], the only place that
  /// knows the total.
  final int percent;

  /// Why [status] is [FileUploadStatus.failed]. Null in every other state.
  final UploadFailure? failure;

  /// Whether a transfer is running and can still be stopped.
  bool get isRunning => status == FileUploadStatus.uploading;

  /// Whether this state is something the user has to dismiss.
  bool get needsAcknowledgement =>
      status == FileUploadStatus.completed ||
      status == FileUploadStatus.cancelled ||
      status == FileUploadStatus.destinationExists ||
      status == FileUploadStatus.failed;
}

// ── Notifier ───────────────────────────────────────────────────────────────

/// Uploads one local file at a time.
///
/// One at a time for the same reason [FileDownloadNotifier] is: the sheet
/// offers exactly one upload affordance, and a second concurrent transfer
/// would have nowhere to show its progress. [start] replaces whatever came
/// before rather than queueing.
class FileUploadNotifier extends Notifier<FileUploadState> {
  @override
  FileUploadState build() => const FileUploadState();

  /// The cancellation for the transfer in flight, or null when none is.
  UploadCancellation? _cancellation;

  /// Uploads [source] to [destinationPath] through [service].
  ///
  /// Returns whether it completed, which is the ONE outcome the caller
  /// needs to act on beyond reporting: [FileBrowserSheet] refreshes its
  /// listing only then, mirroring the refresh-on-success rule
  /// [FileBrowserNotifier.createFolder] already follows for every other
  /// write.
  ///
  /// Never throws \u2014 [SftpUploadService.upload] reports every ending as a
  /// value.
  Future<bool> start(
    SftpUploadService service,
    String destinationPath,
    SafUploadSource source,
  ) async {
    final cancellation = UploadCancellation();
    _cancellation = cancellation;

    state = FileUploadState(
      name: source.name,
      status: FileUploadStatus.uploading,
    );

    final outcome = await service.upload(
      source,
      destinationPath,
      cancellation: cancellation,
      onProgress: (percent) {
        // A newer transfer may have started while this one was in flight;
        // its progress is the current one, and this is a stale echo.
        if (!identical(_cancellation, cancellation)) return;
        state = FileUploadState(
          name: source.name,
          status: FileUploadStatus.uploading,
          percent: percent,
        );
      },
    );

    if (!identical(_cancellation, cancellation)) return false;
    _cancellation = null;

    switch (outcome) {
      case UploadCompleted():
        state = FileUploadState(
          name: source.name,
          status: FileUploadStatus.completed,
          percent: 100,
        );
        return true;

      case UploadCancelled():
        state = FileUploadState(
          name: source.name,
          status: FileUploadStatus.cancelled,
        );
        return false;

      case UploadDestinationExists():
        state = FileUploadState(
          name: source.name,
          status: FileUploadStatus.destinationExists,
        );
        return false;

      case UploadFailed(:final reason):
        state = FileUploadState(
          name: source.name,
          status: FileUploadStatus.failed,
          failure: reason,
        );
        return false;
    }
  }

  /// Stops the transfer in flight, if there is one.
  ///
  /// Only a REQUEST, mirroring [FileDownloadNotifier.cancel]: the engine
  /// notices at the next chunk boundary and reports [UploadCancelled]
  /// itself.
  void cancel() => _cancellation?.cancel();

  /// Clears a finished upload the user has acknowledged.
  void dismiss() {
    _cancellation = null;
    state = const FileUploadState();
  }
}

final fileUploadProvider =
    NotifierProvider<FileUploadNotifier, FileUploadState>(
      FileUploadNotifier.new,
    );
