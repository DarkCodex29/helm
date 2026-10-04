part of '../file_browser_sheet.dart';

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
    required this.showUpload,
    required this.onUpload,
  });

  final String? path;
  final bool canGoUp;
  final Future<void> Function() onUp;
  final Future<void> Function() onRefresh;

  /// Opens the "create a folder" prompt. Null while the browser is not
  /// showing a readable directory — see `FileBrowserSheet.build` for why
  /// a failed or still-loading listing has no directory to create one in.
  final VoidCallback? onCreateFolder;

  /// Whether this platform can pick a local file to upload at all.
  ///
  /// A platform without a picker gets NO BUTTON, not a disabled one —
  /// [UploadSourcePicker]'s own class comment makes the same choice for
  /// the picker itself: a control that always fails is worse than no
  /// control. [onUpload] still decides whether THIS PICKER-CAPABLE
  /// platform's button is enabled right now.
  final bool showUpload;

  /// Opens the local file picker. Null while the browser is not showing a
  /// readable directory, mirroring [onCreateFolder]. Read only when
  /// [showUpload] is true.
  final Future<void> Function()? onUpload;

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
          if (showUpload)
            Semantics(
              identifier: FilesSemantics.uploadButton,
              child: IconButton(
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                color: onUpload == null
                    ? _mutedText.withValues(alpha: 0.4)
                    : _mutedText,
                tooltip: 'Upload a file',
                onPressed: onUpload,
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
