import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:helm/features/files/data/sftp_download_service.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
import 'package:helm/features/files/domain/download_destination.dart';
import 'package:helm/features/files/domain/download_outcome.dart';
import 'package:helm/features/files/domain/remote_entry.dart';
import 'package:helm/features/files/domain/remote_listing.dart';
import 'package:helm/features/files/domain/remote_path.dart';
import 'package:helm/features/files/domain/remote_write_outcome.dart';
import 'package:helm/features/files/domain/upload_outcome.dart';
import 'package:helm/features/files/presentation/providers/download_destination_provider.dart';
import 'package:helm/features/files/presentation/providers/file_browser_provider.dart';
import 'package:helm/features/files/presentation/providers/file_download_provider.dart';
import 'package:helm/features/files/presentation/providers/file_upload_provider.dart';

// ── Split into parts ───────────────────────────────────────────────────────
//
// This library was one 1604-line file holding twenty widgets. It was split
// because its size, not its logic, was the problem: three consecutive
// slices overshot the project's 400-line review budget (847, 482, 602) and
// the cause was recorded as structural rather than fixable by stricter
// briefs.
//
// `part` rather than independent libraries, deliberately. Every widget
// below is library-private and they share seven private palette constants.
// Independent files would force all of them public and rewrite roughly a
// hundred references — turning a verifiable byte-for-byte move into a
// rename sweep, and publishing an internal API that has exactly one
// consumer: this sheet. `part` splits the bytes, which was the goal, and
// keeps the privacy that was already correct.

part 'sheet/name_prompt_dialog.dart';
part 'sheet/transfer_strip.dart';
part 'sheet/destination_bar.dart';
part 'sheet/failure_copy.dart';
part 'sheet/browser_chrome.dart';
part 'sheet/browser_body.dart';
part 'sheet/entry_row.dart';
part 'sheet/formatting.dart';

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
/// This slice reads, DOWNLOADS, WRITES and UPLOADS: it can create a
/// directory, rename an entry, delete one, and send a local file to the
/// host.
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
    required this.uploadService,
    super.key,
  });

  final SftpFileService service;

  /// Fetches a file onto the device. A SEPARATE service from [service] and
  /// deliberately so — see [SftpDownloadService] for why a transfer must
  /// not share the browse session's channel.
  final SftpDownloadService downloadService;

  /// Sends a local file to the host. A SEPARATE service again, for the
  /// identical reason [downloadService] is: [SftpUploadService] opens its
  /// own channel per transfer.
  ///
  /// REQUIRED rather than optional. This sheet is reachable only from
  /// [HomeScreen._buildBrowseAction], which renders nothing at all unless
  /// [TerminalSession.uploadService] is non-null — a live session always
  /// has one the moment it has a [downloadService], since both are built
  /// in the same `connect()` step. An optional parameter here would invite
  /// a caller to construct this sheet without one and silently lose the
  /// upload affordance, which is exactly the unreachable-capability defect
  /// this whole task exists to close.
  final SftpUploadService uploadService;

  /// Opens the browser over the current route.
  static Future<void> show(
    BuildContext context, {
    required SftpFileService service,
    required SftpDownloadService downloadService,
    required SftpUploadService uploadService,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FileBrowserSheet(
        service: service,
        downloadService: downloadService,
        uploadService: uploadService,
      ),
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

  /// Captured for the same reason as [_downloads]: the tap that starts an
  /// upload runs outside a build too.
  late final FileUploadNotifier _uploads;

  @override
  void initState() {
    super.initState();
    _browser = ref.read(fileBrowserProvider.notifier);
    _downloads = ref.read(fileDownloadProvider.notifier);
    _uploads = ref.read(fileUploadProvider.notifier);
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

  /// Picks a local file and uploads it into the directory currently shown.
  ///
  /// Refuses while [FileUploadState.isRunning], mirroring [_download]'s
  /// own refusal and for the identical reason: the strip shows one
  /// transfer, and starting a second would abandon the one on screen with
  /// nothing left to show its progress.
  ///
  /// A DECLINED PICK ends here silently — [UploadSourcePicker.pick]
  /// already folds "nothing to upload" and "this platform cannot pick" into
  /// the same null, and neither is a failure worth a toast.
  ///
  /// Refreshes the listing on completion, matching every other write this
  /// sheet performs: a browser that still omitted the uploaded file would
  /// tell the user their upload did nothing when it worked.
  Future<void> _upload() async {
    if (ref.read(fileUploadProvider).isRunning) return;
    final current = ref.read(fileBrowserProvider).path;
    if (current == null) return;

    final source = await ref.read(uploadSourcePickerProvider).pick();
    if (source == null) return;

    final destinationPath = remoteJoin(current, source.name);
    final completed = await _uploads.start(
      widget.uploadService,
      destinationPath,
      source,
    );
    if (completed) await _browser.refresh();
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
    final upload = ref.watch(fileUploadProvider);
    final notifier = _browser;
    final picker = ref.watch(uploadSourcePickerProvider);

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
                showUpload: picker.supportsPicking,
                onUpload: state.status == FileBrowserStatus.ready
                    ? _upload
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
              _UploadStatusBar(
                state: upload,
                onCancel: _uploads.cancel,
                onDismiss: _uploads.dismiss,
              ),
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
