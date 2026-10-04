part of '../file_browser_sheet.dart';

enum _UploadSource { documents, media }

/// Root-navigator dialog above the browser sheet, anchored to its upload
/// action. Barrier/back decline returns null, not a third source option.
class _UploadSourceDialog extends StatelessWidget {
  const _UploadSourceDialog();

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: FilesSemantics.uploadSourceDialog,
    child: SimpleDialog(
      title: const Text('Upload from'),
      children: [
        Semantics(
          identifier: FilesSemantics.uploadDocumentsOption,
          child: SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_UploadSource.documents),
            child: const Text('Documents'),
          ),
        ),
        Semantics(
          identifier: FilesSemantics.uploadMediaOption,
          child: SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_UploadSource.media),
            child: const Text('Photos and videos'),
          ),
        ),
      ],
    ),
  );
}
