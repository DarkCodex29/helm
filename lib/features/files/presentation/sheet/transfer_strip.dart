part of '../file_browser_sheet.dart';

// Upload strip

/// Reports the one upload the sheet can have in flight.
///
/// A SEPARATE strip from [_DownloadStatusBar] rather than a shared one,
/// see [FilesSemantics.uploadStatus] for why: the two transfers run
/// through independent notifiers and can both have something to say at
/// once.
///
/// Every [UploadOutcome] variant gets its OWN message here, including
/// [UploadDestinationExists], which reads as something the user can act
/// on (pick a different file, or rename what is already there) rather than
/// a generic failure, matching the enum's own doc comment.
class _UploadStatusBar extends StatelessWidget {
  const _UploadStatusBar({
    required this.state,
    required this.onCancel,
    required this.onDismiss,
  });

  final FileUploadState state;
  final VoidCallback onCancel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    if (state.status == FileUploadStatus.idle) return const SizedBox.shrink();

    return Semantics(
      identifier: FilesSemantics.uploadStatus,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
        decoration: const BoxDecoration(
          color: _raised,
          border: Border(top: BorderSide(color: _border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: _line()),
            if (state.isRunning)
              Semantics(
                identifier: FilesSemantics.uploadCancelButton,
                child: TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(foregroundColor: _mutedText),
                  child: const Text('Cancel'),
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                color: _mutedText,
                tooltip: 'Dismiss',
                onPressed: onDismiss,
              ),
          ],
        ),
      ),
    );
  }

  Widget _line() => switch (state.status) {
    FileUploadStatus.uploading => _UploadRunningLine(state: state),
    FileUploadStatus.completed => _EndingLine(
      icon: Icons.check_circle_outline,
      color: _accent,
      message: 'Uploaded ${state.name ?? 'the file'}.',
    ),
    FileUploadStatus.cancelled => const _EndingLine(
      icon: Icons.block,
      color: _mutedText,
      message: 'Upload cancelled.',
    ),
    FileUploadStatus.destinationExists => _EndingLine(
      icon: Icons.warning_amber_outlined,
      color: _danger,
      message:
          '${state.name ?? 'A file'} with that name already exists here. '
          'Rename it on the host, or choose a different file.',
    ),
    FileUploadStatus.failed => _EndingLine(
      icon: Icons.error_outline,
      color: _danger,
      message: describeUploadFailure(state.failure),
    ),
    // Filtered out above; listed so a new status is a compile error here
    // rather than a blank strip.
    FileUploadStatus.idle => const SizedBox.shrink(),
  };
}

class _UploadRunningLine extends StatelessWidget {
  const _UploadRunningLine({required this.state});

  final FileUploadState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Uploading ${state.name ?? ''} · ${state.percent}%',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _primaryText, fontSize: 12),
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: state.percent / 100,
          minHeight: 3,
          backgroundColor: _border,
          valueColor: const AlwaysStoppedAnimation(_accent),
        ),
      ],
    );
  }
}

// Transfer strip

/// Reports the one transfer the sheet can have in flight.
///
/// Rendered as nothing at all when there is nothing to report, so the
/// listing keeps the full height it had before this slice existed.
///
/// ### Two independent lines, one dismiss
///
/// The strip carries up to TWO reports about the same transfer, because
/// there are two questions and their answers do not follow from each
/// other: what happened to the bytes, and where they were filed. A
/// download can open perfectly and fail to reach the user's folder, so the
/// widget cannot be a `switch` over one enum — that shape would force one
/// answer to hide the other.
///
/// The ACTIONS are shared, and deliberately singular. One dismiss for the
/// whole strip rather than one per line: two close buttons stacked in a
/// 60-pixel strip is an interface asking which of two identical things you
/// meant.
///
/// Every state remains ACTIONABLE, which is the rule this widget inherited
/// from slice 2a: a running transfer offers cancel, everything terminal
/// offers dismiss, and a publish that failed for want of a folder also
/// offers to choose one. There is no state here the user can only stare at.
class _DownloadStatusBar extends StatelessWidget {
  const _DownloadStatusBar({
    required this.state,
    required this.onCancel,
    required this.onDismiss,
    required this.onChooseFolder,
  });

  final FileDownloadState state;
  final VoidCallback onCancel;
  final VoidCallback onDismiss;
  final Future<void> Function() onChooseFolder;

  @override
  Widget build(BuildContext context) {
    // A finished-and-opened transfer says nothing about ITSELF: the viewer
    // is already in front of the user, which is the receipt. It may still
    // have something to say about where the file was filed.
    final showsTransfer =
        state.status != FileDownloadStatus.idle &&
        state.status != FileDownloadStatus.opened;
    final showsPublish = state.publishNeedsReporting;
    if (!showsTransfer && !showsPublish) return const SizedBox.shrink();

    return Semantics(
      identifier: FilesSemantics.downloadStatus,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
        decoration: const BoxDecoration(
          color: _raised,
          border: Border(top: BorderSide(color: _border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showsTransfer) _transferLine(),
                  if (showsTransfer && showsPublish) const SizedBox(height: 10),
                  if (showsPublish)
                    _PublishLine(
                      outcome: state.publish!,
                      onChooseFolder: onChooseFolder,
                    ),
                ],
              ),
            ),
            if (state.isRunning)
              Semantics(
                identifier: FilesSemantics.downloadCancelButton,
                child: TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(foregroundColor: _mutedText),
                  child: const Text('Cancel'),
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                color: _mutedText,
                tooltip: 'Dismiss',
                onPressed: onDismiss,
              ),
          ],
        ),
      ),
    );
  }

  Widget _transferLine() => switch (state.status) {
    FileDownloadStatus.downloading => _RunningLine(state: state),
    FileDownloadStatus.noViewer => _NoViewerLine(state: state),
    FileDownloadStatus.cancelled => const _EndingLine(
      icon: Icons.block,
      color: _mutedText,
      message: 'Download cancelled.',
    ),
    FileDownloadStatus.failed => _EndingLine(
      icon: Icons.error_outline,
      color: _danger,
      message: describeDownloadFailure(state.failure),
    ),
    // Both are filtered out above; listed so a new status is a compile
    // error here rather than a blank strip.
    FileDownloadStatus.idle ||
    FileDownloadStatus.opened => const SizedBox.shrink(),
  };
}

class _RunningLine extends StatelessWidget {
  const _RunningLine({required this.state});

  final FileDownloadState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Downloading ${state.entry?.name ?? ''} · ${state.percent}%',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _primaryText, fontSize: 12),
        ),
        const SizedBox(height: 6),
        // Determinate from the first frame: the size is known before any
        // byte is read, so an indeterminate bar would be hiding
        // information the app already has.
        LinearProgressIndicator(
          value: state.percent / 100,
          minHeight: 3,
          backgroundColor: _border,
          valueColor: const AlwaysStoppedAnimation(_accent),
        ),
      ],
    );
  }
}

/// The file arrived, and nothing on the device claimed it.
///
/// Says WHERE the file is rather than only that it could not be opened.
/// That is the difference between a dead end and a next step: the user can
/// reach it from their file manager, or from the Files app on iOS, and the
/// message has to tell them it is worth looking.
class _NoViewerLine extends StatelessWidget {
  const _NoViewerLine({required this.state});

  final FileDownloadState state;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: FilesSemantics.downloadNoViewer,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.help_outline, size: 18, color: _accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${state.entry?.name ?? 'The file'} downloaded, but no app '
                  'on this device can open it.',
                  style: const TextStyle(color: _primaryText, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  'It is saved on the device. Install an app that reads this '
                  'kind of file, then tap it again.',
                  style: TextStyle(
                    color: _mutedText.withValues(alpha: 0.9),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EndingLine extends StatelessWidget {
  const _EndingLine({
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message, style: TextStyle(color: color, fontSize: 12)),
        ),
      ],
    );
  }
}

/// Says where a finished download was filed, or why it was not.
///
/// Present only when there is something to say —
/// [FileDownloadState.publishNeedsReporting] is what decides that, and it
/// excludes the platform that files downloads by itself.
///
/// The successful case is reported rather than left silent, which is worth
/// stating because a receipt for something that worked is easy to trim.
/// It is the answer to the question this whole slice exists to answer, the
/// name it was saved under is not always the name that was asked for, and
/// the viewer that opens next is showing the app's own staged copy — so
/// nothing else on screen tells the user their folder now holds this file.
class _PublishLine extends StatelessWidget {
  const _PublishLine({required this.outcome, required this.onChooseFolder});

  final PublishOutcome outcome;
  final Future<void> Function() onChooseFolder;

  @override
  Widget build(BuildContext context) {
    final (icon, color, message, offersFolder) = switch (outcome) {
      PublishedToFolder(:final folderName, :final fileName) => (
        Icons.check_circle_outline,
        _accent,
        'Saved to $folderName as $fileName.',
        false,
      ),
      PublishNotConfigured() => (
        Icons.folder_off_outlined,
        _mutedText,
        'Not saved to a folder yet. Downloads stay in the app for a day '
            'unless you choose somewhere to keep them.',
        true,
      ),
      PublishFailed(:final reason) => (
        Icons.folder_off_outlined,
        _danger,
        describePublishFailure(reason),
        // Every failure except a full disk means the destination has to be
        // named again; offering the picker for a storage failure would
        // suggest the folder was the problem when it was not.
        reason != PublishFailure.storage,
      ),
      // Filtered out before this widget is built. Listed so a new outcome
      // is a compile error rather than a blank line.
      PublishNotNeeded() => (Icons.check, _mutedText, '', false),
    };

    return Semantics(
      identifier: FilesSemantics.downloadPublish,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message, style: TextStyle(color: color, fontSize: 11)),
                if (offersFolder)
                  TextButton(
                    onPressed: onChooseFolder,
                    style: TextButton.styleFrom(
                      foregroundColor: _accent,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Choose a folder',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
