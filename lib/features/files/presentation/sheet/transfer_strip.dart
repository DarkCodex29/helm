part of '../file_browser_sheet.dart';

// Upload strip

/// Reports a FIFO without spending a phone screen on pending rows.
/// Only the active (or next pending) item gets progress detail; precomputed
/// counts summarize the rest. Terminal receipts stay in an 80-pixel scroll
/// area so renamed successes and failures are never overwritten by the next
/// item. "Done" means ended, not necessarily succeeded.
///
/// Actions belong to the QUEUE: Cancel all stops active and pending work;
/// one dismiss acknowledges all terminal history. No per-item cancel here:
/// adding identical row actions would contradict the singular-action rule
/// below and make a compact strip ambiguous. Pending-only work can cancel
/// too; cancellation cleanup keeps cancel available until actually terminal.
///
/// A SEPARATE strip from [_DownloadStatusBar] rather than a shared one,
/// see [FilesSemantics.uploadStatus] for why: the two transfers run
/// through independent notifiers and can both have something to say at
/// once.
///
/// Every [UploadOutcome] variant gets its OWN message here, including
/// [UploadDestinationExists], which reads as something the user can act
/// on (try a different name after bounded search exhaustion) rather than
/// a generic failure. Successful receipts use the service's actual name.
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
    if (state.items.isEmpty) return const SizedBox.shrink();

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
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (state.remainingCount > 0)
                    _line(
                      state.items.firstWhere(
                        (item) => item.status == FileUploadStatus.uploading,
                        orElse: () => state.items.firstWhere(
                          (item) => item.status == FileUploadStatus.pending,
                        ),
                      ),
                    ),
                  Text(
                    '${state.doneCount} done · ${state.remainingCount} remaining',
                    style: const TextStyle(color: _mutedText, fontSize: 12),
                  ),
                  if (state.doneCount > 0)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 80),
                      // NEWEST FIRST, and a visible scrollbar.
                      //
                      // Queue order put late receipts at the bottom of an
                      // 80-pixel box with no scrollbar and no cue, so a
                      // failure at the end of a batch sat below the fold
                      // while the user saw only the early successes — and
                      // a failure is the receipt they need. Flagged as
                      // cosmetic by an adversarial review; see
                      // odd/reviews/queue-and-strip.md.
                      //
                      // Reversing rather than auto-scrolling: no
                      // controller, no animation to race, and correct at
                      // every moment rather than one frame after each new
                      // receipt arrives.
                      child: Scrollbar(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final item in state.items.reversed)
                                if (item.isTerminal) _line(item),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (state.remainingCount > 0)
              Semantics(
                identifier: FilesSemantics.uploadCancelButton,
                child: TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(foregroundColor: _mutedText),
                  child: const Text('Cancel all'),
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

  Widget _line(FileUploadItem item) => switch (item.status) {
    FileUploadStatus.uploading => _UploadRunningLine(state: item),
    FileUploadStatus.completed => _EndingLine(
      icon: Icons.check_circle_outline,
      color: _accent,
      message: switch (item.outcome) {
        UploadCompleted(:final name) when name != item.name =>
          'Uploaded ${item.name} as $name.',
        _ => 'Uploaded ${item.name}.',
      },
    ),
    // NAMES THE FILE, like every other receipt here. Cancellation and
    // failure were the two that did not, so once the active line moved to
    // the next item the user could no longer tell WHICH file it was, and
    // several failures rendered as indistinguishable receipts with nothing
    // to identify a retry target. Found by an adversarial review — see
    // odd/reviews/queue-and-strip.md.
    FileUploadStatus.cancelled => _EndingLine(
      icon: Icons.block,
      color: _mutedText,
      message: 'Cancelled ${item.name}.',
    ),
    FileUploadStatus.destinationExists => _EndingLine(
      icon: Icons.warning_amber_outlined,
      color: _danger,
      message:
          'Could not find a free name for ${item.name} after checking '
          '100 names. Try a different name.',
    ),
    FileUploadStatus.failed => _EndingLine(
      icon: Icons.error_outline,
      color: _danger,
      // The name is PREFIXED rather than folded into the reason: every
      // string `describeUploadFailure` returns is written to stand alone
      // as a complete sentence, and rewrapping them to carry a filename
      // would mean maintaining two phrasings of each failure.
      message: '${item.name}: ${describeUploadFailure(item.failure)}',
    ),
    FileUploadStatus.pending => _EndingLine(
      icon: Icons.schedule,
      color: _mutedText,
      message: 'Waiting to upload ${item.name}.',
    ),
  };
}

class _UploadRunningLine extends StatelessWidget {
  const _UploadRunningLine({required this.state});

  final FileUploadItem state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Uploading ${state.name} · ${state.percent}%',
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
