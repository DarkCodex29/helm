import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/domain/download_destination.dart';
import 'package:helm/features/files/domain/download_outcome.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/domain/remote_listing.dart';
import 'package:helm/features/files/domain/remote_write_outcome.dart';
import 'package:helm/features/files/presentation/providers/download_destination_provider.dart';
import 'package:helm/features/files/presentation/providers/file_browser_provider.dart';
import 'package:helm/features/files/presentation/providers/file_download_provider.dart';

// The drawer's palette, repeated rather than imported because this app has
// no token file yet and every surface spells these out — see
// shortcuts_drawer.dart. Worth centralizing, but not from here.
const _surface = AppTheme.surface;
const _raised = AppTheme.surfaceVariant;
const _border = AppTheme.divider;
const _primaryText = AppTheme.onBackground;
const _mutedText = AppTheme.onSurfaceMuted;
const _accent = AppTheme.primary;
const _danger = AppTheme.error;

/// Browses the remote filesystem of one connection.
///
/// Presented as a modal sheet rather than a route: it is bound to a live
/// [SftpFileService], and go_router's routes here are all built from a
/// path with no session in scope (`app_router.dart:61-83`). Threading a
/// connection through a URL would mean either a global lookup or a route
/// that can be deep-linked into a session that no longer exists.
///
/// This slice reads, DOWNLOADS, and WRITES: it can create a directory,
/// rename an entry, and delete one. Upload — streaming bytes INTO the
/// host — is still not offered; see `SftpSession`'s doc comment for why
/// that boundary is deliberate rather than an oversight.
///
/// Every download passes through a staging directory the app sweeps on a
/// 24-hour retention ([SftpDownloadService.defaultDownloadDirectory]), and
/// that is the copy a viewer is handed. Where it is KEPT is a separate
/// question with a separate answer — see [_DestinationBar] — and the sheet
/// reports the two independently, because a file can open perfectly while
/// failing to reach the folder the user picked.
class FileBrowserSheet extends ConsumerStatefulWidget {
  const FileBrowserSheet({
    required this.service,
    required this.downloadService,
    super.key,
  });

  final SftpFileService service;

  /// Fetches a file onto the device. A SEPARATE service from [service] and
  /// deliberately so — see [SftpDownloadService] for why a transfer must
  /// not share the browse session's channel.
  final SftpDownloadService downloadService;

  /// Opens the browser over the current route.
  static Future<void> show(
    BuildContext context, {
    required SftpFileService service,
    required SftpDownloadService downloadService,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          FileBrowserSheet(service: service, downloadService: downloadService),
    );
  }

  @override
  ConsumerState<FileBrowserSheet> createState() => _FileBrowserSheetState();
}

class _FileBrowserSheetState extends ConsumerState<FileBrowserSheet> {
  /// The entry the user last tapped, if it was not a directory.
  ///
  /// Held in widget state rather than in [FileBrowserState] because it is
  /// a property of THIS sheet, not of the browsing session: dismissing and
  /// reopening should not restore a selection, and nothing outside this
  /// widget reads it.
  RemoteEntry? _selected;

  /// The notifier, captured while [ref] is still usable.
  ///
  /// Read once in [initState] rather than on every build, because `ref` is
  /// off-limits outside a build and this widget's callbacks run outside
  /// one. The notifier belongs to the enclosing [ProviderScope] and
  /// outlives this sheet.
  late final FileBrowserNotifier _browser;

  /// Captured for the same reason as [_browser]: the tap that starts a
  /// download runs outside a build, where `ref` is off-limits.
  late final FileDownloadNotifier _downloads;

  @override
  void initState() {
    super.initState();
    _browser = ref.read(fileBrowserProvider.notifier);
    _downloads = ref.read(fileDownloadProvider.notifier);
    // Deferred to the first frame: `open` writes to the provider, and a
    // provider must not be mutated while the widget tree is still
    // building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _browser.open(widget.service);
    });
  }

  // Deliberately NO dispose() that clears the provider.
  //
  // Both obvious spellings are wrong, and both were tried: calling
  // `ref.read` in `dispose` throws `Cannot use "ref" after the widget was
  // disposed`, and calling the captured notifier's `reset` there writes to
  // a provider this element is still listening to WHILE it is being
  // unmounted, which trips `_lifecycleState != defunct` inside
  // `markNeedsBuild`.
  //
  // Clearing belongs to [FileBrowserNotifier.open] instead, whose first
  // act — before it awaits anything — is to blank the state. A reopened
  // sheet therefore never renders the previous session's directory, which
  // is the only thing the teardown was protecting.

  /// Starts a download, unless one is already moving bytes.
  ///
  /// Refusing while [FileDownloadState.isRunning] rather than replacing:
  /// the strip shows one transfer, and silently abandoning the one the
  /// user is watching because they brushed another row is worse than
  /// doing nothing.
  Future<void> _download(RemoteEntry entry) async {
    if (ref.read(fileDownloadProvider).isRunning) return;
    setState(() => _selected = null);
    await _downloads.start(widget.downloadService, entry);
  }

  /// Opens the system folder picker.
  ///
  /// Offered from the transfer strip as well as from [_DestinationBar],
  /// because the moment a user most wants to answer "where should this be
  /// kept" is the moment they have just been told it was not kept
  /// anywhere.
  Future<void> _chooseFolder() =>
      ref.read(downloadDestinationProvider.notifier).choose();

  /// Reports a write outcome the way the sheet reports everything else
  /// that is not rendered inline: a [SnackBar]. There is no strip for
  /// these three operations the way there is for a download, so a toast is
  /// the cheapest way to make a silent success or a silent failure
  /// impossible — see the class's "delete must say so" rule.
  void _report(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? _danger : null,
      ),
    );
  }

  /// Prompts for a folder name and creates it, reporting whatever happened.
  ///
  /// Name validation happens entirely inside
  /// [FileBrowserNotifier.createFolder] — see [validateRemoteName] — so
  /// this dialog has no local re-implementation of "is this name legal"
  /// to drift out of sync with the service's own rule.
  Future<void> _createFolder() async {
    final name = await _promptForName(
      title: 'New folder',
      label: 'Folder name',
      confirmLabel: 'Create',
      confirmSemanticsId: FilesSemantics.createFolderConfirmButton,
    );
    if (name == null) return;

    final outcome = await _browser.createFolder(name);
    switch (outcome) {
      case MkdirCreated():
        _report('Created "$name".');
      case MkdirInvalidName(:final reason):
        _report(describeNameRejection(reason), isError: true);
      case MkdirAlreadyExists():
        _report('"$name" already exists here.', isError: true);
      case MkdirFailed(:final reason):
        _report(describeRemoteWriteFailure(reason), isError: true);
    }
  }

  /// Prompts for a new name for [entry] and renames it.
  Future<void> _rename(RemoteEntry entry) async {
    final name = await _promptForName(
      title: 'Rename',
      label: 'New name',
      initialValue: entry.name,
      confirmLabel: 'Rename',
      confirmSemanticsId: FilesSemantics.renameConfirmButton,
    );
    if (name == null) return;

    final outcome = await _browser.renameEntry(entry, name);
    switch (outcome) {
      case RenameCompleted():
        _report('Renamed to "$name".');
      case RenameInvalidName(:final reason):
        _report(describeNameRejection(reason), isError: true);
      case RenameUnchanged():
        // Nothing happened, and nothing needed to: the name the user
        // typed is the name the entry already had.
        break;
      case RenameDestinationExists():
        _report('"$name" already exists here.', isError: true);
      case RenameFailed(:final reason):
        _report(describeRemoteWriteFailure(reason), isError: true);
    }
  }

  /// Shows a text-entry dialog and returns the trimmed name the user
  /// confirmed, or null if they cancelled.
  ///
  /// Trimmed here rather than left to the caller: every caller immediately
  /// hands the result to a service method that trims again internally, so
  /// trimming once up front just means the confirmation label the dialog
  /// shows matches what is actually sent.
  Future<String?> _promptForName({
    required String title,
    required String label,
    required String confirmLabel,
    required String confirmSemanticsId,
    String? initialValue,
  }) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => _NamePromptDialog(
        title: title,
        label: label,
        confirmLabel: confirmLabel,
        confirmSemanticsId: confirmSemanticsId,
        initialValue: initialValue,
      ),
    );
  }

  /// Confirms, then deletes [entry].
  ///
  /// Confirmation names what is about to be destroyed INCLUDING whether it
  /// is a folder — the two requirements the class-level warning on this
  /// slice called out by name — and does not say the action is safe,
  /// following the precedent `TrustedHostsScreen._confirmForget` set:
  /// a confirmation whose copy reassures the user is a confirmation that
  /// stops meaning anything.
  Future<void> _delete(RemoteEntry entry) async {
    final isDirectory = entry.kind == RemoteEntryKind.directory;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete this ${isDirectory ? 'folder' : 'file'}?'),
        content: Text(
          isDirectory
              ? 'This will permanently delete the folder "${entry.name}" from '
                    'the host. This cannot be undone.'
              : 'This will permanently delete the file "${entry.name}" from '
                    'the host. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          Semantics(
            identifier: FilesSemantics.deleteConfirmButton,
            child: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              child: const Text('Delete'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _selected = null);
    final outcome = await _browser.deleteEntry(entry);
    switch (outcome) {
      case DeleteCompleted():
        _report('Deleted "${entry.name}".');
      case DeleteDirectoryNotEmpty():
        _report(
          '"${entry.name}" is not empty. Remove its contents first.',
          isError: true,
        );
      case DeleteFailed(:final reason):
        _report(describeRemoteWriteFailure(reason), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(fileBrowserProvider);
    final download = ref.watch(fileDownloadProvider);
    final notifier = _browser;

    return Semantics(
      identifier: FilesSemantics.sheet,
      child: FractionallySizedBox(
        heightFactor: 0.85,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            border: Border(top: BorderSide(color: _border)),
          ),
          child: Column(
            children: [
              const _Grabber(),
              _PathBar(
                path: state.path,
                canGoUp: state.canGoUp,
                onUp: notifier.goUp,
                onRefresh: notifier.refresh,
                // Only offered once a directory is actually showing: a
                // loading or failed listing has no known parent to create
                // the folder in.
                onCreateFolder: state.status == FileBrowserStatus.ready
                    ? _createFolder
                    : null,
              ),
              Expanded(
                child: Semantics(
                  identifier: FilesSemantics.listing,
                  child: _Body(
                    state: state,
                    selected: _selected,
                    onRetry: notifier.refresh,
                    onRename: _rename,
                    onDelete: _delete,
                    onTap: (entry) async {
                      if (entry.isNavigable) {
                        setState(() => _selected = null);
                        await notifier.enter(entry);
                        return;
                      }
                      if (entry.isDownloadable) {
                        await _download(entry);
                        return;
                      }
                      // Everything left is something this app can neither
                      // enter nor fetch — a socket, a device, a broken
                      // link. Tapping selects it so its description is
                      // readable, which is all there is to offer.
                      setState(
                        () => _selected = _selected == entry ? null : entry,
                      );
                    },
                  ),
                ),
              ),
              const _DestinationBar(),
              _DownloadStatusBar(
                state: download,
                onCancel: _downloads.cancel,
                onDismiss: _downloads.dismiss,
                onChooseFolder: _chooseFolder,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A name-entry dialog, as its own [StatefulWidget] rather than a
/// [TextEditingController] built inline by the sheet's method.
///
/// That inline shape was tried first and crashed under test: a controller
/// created and `dispose()`d by a plain method raced the dialog route's own
/// teardown animation, and `TextField` rebuilt against an already-disposed
/// controller while the route was still closing — `ChangeNotifier` used
/// after `dispose()`. Giving the dialog its own `State` makes the
/// controller's lifecycle match the WIDGET that reads it, which is the
/// ownership `TextEditingController`'s own contract assumes and the inline
/// version violated.
class _NamePromptDialog extends StatefulWidget {
  const _NamePromptDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
    required this.confirmSemanticsId,
    this.initialValue,
  });

  final String title;
  final String label;
  final String confirmLabel;
  final String confirmSemanticsId;
  final String? initialValue;

  @override
  State<_NamePromptDialog> createState() => _NamePromptDialogState();
}

class _NamePromptDialogState extends State<_NamePromptDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        Semantics(
          identifier: widget.confirmSemanticsId,
          child: TextButton(
            onPressed: _submit,
            child: Text(widget.confirmLabel),
          ),
        ),
      ],
    );
  }
}

// ── Transfer strip ─────────────────────────────────────────────────────────

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

/// Names the folder downloads are being kept in, and lets it be changed.
///
/// Sits below the listing and above the transfer strip, PERSISTENTLY, so
/// the answer to "where do my files go" is available with nothing in
/// flight. An icon in the toolbar would have been cheaper in pixels and
/// would not have answered the question — and a setting reachable only
/// from a failure message is a setting the user meets exactly once, at the
/// worst moment.
///
/// Absent entirely where there is no folder to choose. On iOS this bar
/// would be an offer to fix something that is not broken: downloads
/// already land in a Files-visible folder, so the row would cost height on
/// every use of the sheet to say nothing.
class _DestinationBar extends ConsumerWidget {
  const _DestinationBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.watch(downloadDestinationProvider.notifier);
    if (!notifier.supportsFolderChoice) return const SizedBox.shrink();

    final destination = ref.watch(downloadDestinationProvider);
    // A folder is read off disk once at startup. Rendering a spinner for
    // that would flicker on a sheet that is already showing content, so
    // the row simply stays out of the way until the answer is known.
    if (destination.isLoading) return const SizedBox.shrink();

    final folder = destination.valueOrNull;

    return Semantics(
      identifier: FilesSemantics.downloadFolderButton,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: _border)),
        ),
        child: Row(
          children: [
            Icon(
              folder == null
                  ? Icons.folder_off_outlined
                  : Icons.folder_outlined,
              size: 14,
              color: _mutedText,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                folder == null
                    ? 'Downloads are not being saved to a folder'
                    : 'Saving downloads to ${folder.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _mutedText, fontSize: 11),
              ),
            ),
            if (folder == null)
              TextButton(
                onPressed: () =>
                    ref.read(downloadDestinationProvider.notifier).choose(),
                style: TextButton.styleFrom(
                  foregroundColor: _accent,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Choose', style: TextStyle(fontSize: 11)),
              )
            else
              PopupMenuButton<_DestinationAction>(
                icon: const Icon(Icons.more_horiz, size: 16),
                color: _raised,
                tooltip: 'Download folder',
                onSelected: (action) => switch (action) {
                  _DestinationAction.change =>
                    ref.read(downloadDestinationProvider.notifier).choose(),
                  _DestinationAction.forget =>
                    ref.read(downloadDestinationProvider.notifier).forget(),
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: _DestinationAction.change,
                    child: Text(
                      'Choose a different folder',
                      style: TextStyle(color: _primaryText, fontSize: 13),
                    ),
                  ),
                  PopupMenuItem(
                    value: _DestinationAction.forget,
                    child: Text(
                      'Stop saving to a folder',
                      style: TextStyle(color: _primaryText, fontSize: 13),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

enum _DestinationAction { change, forget }

/// One sentence per reason a download could not be filed where the user
/// asked.
///
/// Public for the same reason [describeDownloadFailure] is: a widget test
/// asserts on the exact string without reaching into a private widget.
///
/// Every one of these says the file IS still on the device, because that
/// is the fact most at risk of being lost here. The bytes arrived; only
/// the copy into the user's folder did not, and a message that mentioned
/// only the failure would read as a failed download.
String describePublishFailure(PublishFailure failure) => switch (failure) {
  PublishFailure.permissionLost =>
    'The file is on this device, but Helm lost access to your download '
        'folder. Choose it again to keep saving there.',
  PublishFailure.destinationMissing =>
    'The file is on this device. Your download folder no longer exists, so '
        'nothing was saved to it.',
  PublishFailure.storage =>
    'The file is on this device, but there was no room to save a copy in '
        'your download folder.',
  PublishFailure.unknown =>
    'The file is on this device. It could not be saved to your download '
        'folder, and the system did not say why.',
};

/// One sentence per reason a download stopped.
///
/// Public so a widget test can assert on the exact string without reaching
/// into a private widget, matching [describeRemoteEntry].
///
/// Written from the [DownloadFailure] alone and never from the underlying
/// message: [DownloadFailed.detail] carries whatever the server said, and
/// a server-supplied string must not become UI copy.
String describeDownloadFailure(DownloadFailure? failure) => switch (failure) {
  DownloadFailure.permissionDenied =>
    'You do not have permission to read this file.',
  DownloadFailure.notFound => 'This file no longer exists on the host.',
  DownloadFailure.disconnected =>
    'The connection dropped before the file finished downloading.',
  DownloadFailure.stalled =>
    'The download stopped receiving data and was abandoned.',
  DownloadFailure.unknownSize =>
    'The host would not say how large this file is, so it was not downloaded.',
  DownloadFailure.sizeMismatch =>
    'The file arrived incomplete and was discarded.',
  DownloadFailure.storage =>
    'There was not enough room on this device to save the file.',
  DownloadFailure.unknown ||
  null => 'The file could not be downloaded, and the host did not say why.',
};

/// One sentence per locally-rejected name, matching [describeDownloadFailure]
/// in being written from the enum alone — there is no server round trip to
/// carry a message, which is the whole point of validating locally.
String describeNameRejection(NameRejection reason) => switch (reason) {
  NameRejection.empty => 'Enter a name.',
  NameRejection.containsSeparator => 'A name cannot contain "/".',
  NameRejection.currentDirectory => '"." is not a usable name.',
  NameRejection.parentDirectory => '".." is not a usable name.',
};

/// One sentence per reason a create, rename or delete was refused by the
/// server, mirroring [describeDownloadFailure]: never built from the
/// underlying message, only from the classified reason.
String describeRemoteWriteFailure(RemoteWriteFailure reason) =>
    switch (reason) {
      RemoteWriteFailure.permissionDenied =>
        'You do not have permission to do this.',
      RemoteWriteFailure.notFound => 'This entry no longer exists on the host.',
      RemoteWriteFailure.disconnected =>
        'The connection dropped before this could finish.',
      RemoteWriteFailure.unknown =>
        'The host refused this, without saying why.',
    };

// ── Chrome ─────────────────────────────────────────────────────────────────

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 4,
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: _border,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// Names where the browser is, and offers the only two moves it has.
///
/// The path is shown in full and ellipsized at the START, so a deep path
/// keeps the part that identifies it — the last segments — rather than the
/// `/Users/...` prefix every path on the host shares.
class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.path,
    required this.canGoUp,
    required this.onUp,
    required this.onRefresh,
    required this.onCreateFolder,
  });

  final String? path;
  final bool canGoUp;
  final Future<void> Function() onUp;
  final Future<void> Function() onRefresh;

  /// Opens the "create a folder" prompt. Null while the browser is not
  /// showing a readable directory — see `FileBrowserSheet.build` for why
  /// a failed or still-loading listing has no directory to create one in.
  final VoidCallback? onCreateFolder;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Row(
        children: [
          Semantics(
            identifier: FilesSemantics.upButton,
            child: IconButton(
              icon: const Icon(Icons.arrow_upward, size: 18),
              color: canGoUp ? _accent : _mutedText.withValues(alpha: 0.4),
              tooltip: 'Parent directory',
              // Disabled at the root rather than hidden: a control that
              // disappears makes the row jump, and its absence would not
              // explain itself.
              onPressed: canGoUp ? onUp : null,
            ),
          ),
          Expanded(
            child: Semantics(
              identifier: FilesSemantics.pathBar,
              child: Text(
                path ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.rtl,
                style: const TextStyle(
                  color: _primaryText,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          Semantics(
            identifier: FilesSemantics.createFolderButton,
            child: IconButton(
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              color: onCreateFolder == null
                  ? _mutedText.withValues(alpha: 0.4)
                  : _mutedText,
              tooltip: 'New folder',
              onPressed: onCreateFolder,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            color: _mutedText,
            tooltip: 'Reload',
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

// ── Body ───────────────────────────────────────────────────────────────────

/// Renders exactly one of the four states, with no fall-through.
///
/// A `switch` over the enum rather than nested `if`s, so adding a state
/// later is a compile error here instead of a silently blank sheet.
class _Body extends StatelessWidget {
  const _Body({
    required this.state,
    required this.selected,
    required this.onTap,
    required this.onRetry,
    required this.onRename,
    required this.onDelete,
  });

  final FileBrowserState state;
  final RemoteEntry? selected;
  final Future<void> Function(RemoteEntry) onTap;
  final Future<void> Function() onRetry;
  final void Function(RemoteEntry) onRename;
  final void Function(RemoteEntry) onDelete;

  @override
  Widget build(BuildContext context) {
    switch (state.status) {
      case FileBrowserStatus.idle:
      case FileBrowserStatus.loading:
        return const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
          ),
        );

      case FileBrowserStatus.failed:
        return _ListingError(
          failure: state.failure ?? RemoteListingFailure.unknown,
          onRetry: onRetry,
        );

      case FileBrowserStatus.ready:
        if (state.entries.isEmpty) return const _EmptyDirectory();
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: state.entries.length,
          itemBuilder: (_, i) {
            final entry = state.entries[i];
            return _EntryRow(
              key: ValueKey(entry.path),
              entry: entry,
              isSelected: entry == selected,
              onTap: () => onTap(entry),
              onRename: () => onRename(entry),
              onDelete: () => onDelete(entry),
            );
          },
        );
    }
  }
}

/// The directory was read and held nothing.
///
/// A DIFFERENT widget from [_ListingError], with a different semantic id,
/// because these two are the pair this feature most needs to keep apart —
/// see [FilesSemantics.emptyDirectory].
class _EmptyDirectory extends StatelessWidget {
  const _EmptyDirectory();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: FilesSemantics.emptyDirectory,
      child: const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open, size: 32, color: _mutedText),
              SizedBox(height: 12),
              Text(
                'This directory is empty',
                style: TextStyle(color: _mutedText, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The directory was NOT read, and nothing is known about its contents.
class _ListingError extends StatelessWidget {
  const _ListingError({required this.failure, required this.onRetry});

  final RemoteListingFailure failure;
  final Future<void> Function() onRetry;

  /// One sentence per reason, written as a statement about what happened
  /// rather than as an apology, and never as a claim about contents.
  String get _message => switch (failure) {
    RemoteListingFailure.permissionDenied =>
      'You do not have permission to read this directory.',
    RemoteListingFailure.notFound =>
      'This directory no longer exists on the host.',
    RemoteListingFailure.disconnected =>
      'The connection dropped before this directory could be read.',
    RemoteListingFailure.unknown =>
      'The host refused to read this directory, without saying why.',
  };

  IconData get _icon => switch (failure) {
    RemoteListingFailure.permissionDenied => Icons.lock_outline,
    RemoteListingFailure.notFound => Icons.search_off,
    RemoteListingFailure.disconnected => Icons.link_off,
    RemoteListingFailure.unknown => Icons.error_outline,
  };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: FilesSemantics.listingError,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon, size: 32, color: _danger),
              const SizedBox(height: 12),
              Text(
                _message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _danger, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Try again'),
                style: TextButton.styleFrom(foregroundColor: _accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Entry row ──────────────────────────────────────────────────────────────

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.isSelected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    super.key,
  });

  final RemoteEntry entry;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      tileColor: isSelected ? _raised : null,
      leading: Icon(_iconFor(entry), size: 20, color: _colorFor(entry)),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: _primaryText, fontSize: 14),
      ),
      subtitle: Text(
        describeRemoteEntry(entry),
        style: const TextStyle(color: _mutedText, fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.isNavigable)
            const Icon(Icons.chevron_right, size: 18, color: _mutedText),
          Semantics(
            identifier: FilesSemantics.entryMenuButton(entry.path),
            child: PopupMenuButton<_EntryAction>(
              icon: const Icon(Icons.more_vert, size: 18, color: _mutedText),
              color: _raised,
              tooltip: 'More actions',
              onSelected: (action) => switch (action) {
                _EntryAction.rename => onRename(),
                _EntryAction.delete => onDelete(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _EntryAction.rename,
                  child: Semantics(
                    identifier: FilesSemantics.renameMenuItem,
                    child: const Text(
                      'Rename',
                      style: TextStyle(color: _primaryText, fontSize: 13),
                    ),
                  ),
                ),
                PopupMenuItem(
                  value: _EntryAction.delete,
                  child: Semantics(
                    identifier: FilesSemantics.deleteMenuItem,
                    child: const Text(
                      'Delete',
                      style: TextStyle(color: _danger, fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  static IconData _iconFor(RemoteEntry entry) => switch (entry.kind) {
    RemoteEntryKind.directory => Icons.folder,
    RemoteEntryKind.symlink => Icons.link,
    RemoteEntryKind.file => Icons.insert_drive_file_outlined,
    RemoteEntryKind.other => Icons.help_outline,
  };

  static Color _colorFor(RemoteEntry entry) =>
      entry.isNavigable ? _accent : _mutedText;
}

/// The two destructive-adjacent actions every row offers through
/// [FilesSemantics.entryMenuButton].
///
/// Rename and delete rather than a free-for-all menu, matching the scope
/// this slice was built for — see `SftpSession`'s widened-seam doc comment.
enum _EntryAction { rename, delete }

// ── Formatting ─────────────────────────────────────────────────────────────

/// The secondary line under an entry's name.
///
/// Public so a widget test can assert on the exact string a row shows
/// without reaching into a private widget.
///
/// States what the entry IS first, then only what is known about it.
/// Absent facts are OMITTED rather than rendered as `0 B` or `—`: every
/// `SftpFileAttrs` field is optional, and a zero-byte file has to stay
/// distinguishable from a server that did not send a size.
String describeRemoteEntry(RemoteEntry entry) {
  final parts = <String>[_describeKind(entry)];

  final size = entry.size;
  if (size != null && entry.kind == RemoteEntryKind.file) {
    parts.add(formatByteSize(size));
  }

  final modified = entry.modifiedAt;
  if (modified != null) parts.add(formatRemoteDate(modified));

  return parts.join(' · ');
}

String _describeKind(RemoteEntry entry) => switch (entry.kind) {
  RemoteEntryKind.directory => 'Directory',
  RemoteEntryKind.file => 'File',
  RemoteEntryKind.other => 'Special file',
  RemoteEntryKind.symlink => switch (entry.linkTarget) {
    RemoteEntryKind.directory => 'Link to directory',
    RemoteEntryKind.file => 'Link to file',
    // Covers both "points at something exotic" and "we could not follow
    // it", which are not worth telling apart on one line of a list row.
    _ => 'Link',
  },
};

/// [bytes] in the largest unit that keeps it under 1024.
///
/// Binary units (1024) with SI-looking labels, which is the convention
/// `ls -lh` and every file manager on a POSIX host already uses — matching
/// the tool the user would otherwise run in the terminal beside this.
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';

  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // One decimal below 10, none above: "9.8 MB" is useful precision,
  // "812.4 MB" is noise.
  final formatted = value < 10
      ? value.toStringAsFixed(1)
      : value.round().toString();
  return '$formatted ${units[unit]}';
}

/// [moment] as a short, unambiguous date.
///
/// ISO-ordered (`2026-08-27 14:05`) rather than localized, because this
/// list sorts by name and a reader scanning dates down a column needs them
/// to line up. No relative phrasing: "2 days ago" is a moving target on a
/// screen the user may leave open.
String formatRemoteDate(DateTime moment) {
  final local = moment.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
