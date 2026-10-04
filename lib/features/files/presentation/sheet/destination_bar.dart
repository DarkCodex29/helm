part of '../file_browser_sheet.dart';

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
