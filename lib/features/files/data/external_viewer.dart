import 'dart:io';

import 'package:open_filex/open_filex.dart';

/// What happened when the device was asked to open a file.
///
/// [noViewer] is a FIRST-CLASS outcome, not an error, and that is the
/// reason this enum exists instead of a `bool` plus a thrown exception.
/// Handing a `.docx` to a phone with no office app is an ordinary thing to
/// happen, it is entirely the user's situation rather than a fault, and
/// the app has something useful to say about it — so it gets a name.
enum ViewerOutcome {
  /// The platform handed the file to an app.
  ///
  /// Note what this does NOT claim: that the app rendered it. Android's
  /// `startActivity` returns as soon as the intent is delivered, so a
  /// viewer that opens and then reports a corrupt file still lands here.
  opened,

  /// Nothing installed can open this kind of file.
  noViewer,

  /// The platform could not find the file this app just wrote.
  fileMissing,

  /// The platform refused access to the file.
  permissionDenied,

  /// The platform failed for some other reason.
  failed,
}

/// Hands a downloaded file to whatever the device uses to view it.
typedef ExternalViewer = Future<ViewerOutcome> Function(File file);

/// Opens [file] with `open_filex` and translates its reply.
///
/// ### Why nothing is pre-checked
///
/// The obvious shape — ask whether anything can open this, then either
/// open it or explain — cannot be built correctly on Android. Package
/// visibility filtering (targetSdk 30+) makes `resolveActivity` return
/// null for apps this one has not declared in `<queries>`, so the check
/// reports "nothing can open this" while a perfectly good viewer sits on
/// the device. Declaring every office MIME type in `<queries>` to repair
/// the check would be a manifest that lies about what this app integrates
/// with. So: invoke, then read the answer.
///
/// ### No FileProvider is declared for this
///
/// `open_filex` ships its own, authority
/// `${applicationId}.fileProvider.com.crazecoder.openfile`, exporting
/// `cache-path`, `files-path` and `root-path`
/// (`open_filex-4.7.0/android/src/main/AndroidManifest.xml` and
/// `res/xml/filepaths.xml`) — verified by reading the installed plugin.
/// Both directories [SftpDownloadService.defaultDownloadDirectory] can
/// return are already covered. Adding a second provider would collide on
/// the authority and fail the manifest merge.
Future<ViewerOutcome> openWithPlatformViewer(File file) async {
  final result = await OpenFilex.open(file.path);
  return switch (result.type) {
    ResultType.done => ViewerOutcome.opened,
    ResultType.noAppToOpen => ViewerOutcome.noViewer,
    ResultType.fileNotFound => ViewerOutcome.fileMissing,
    ResultType.permissionDenied => ViewerOutcome.permissionDenied,
    ResultType.error => ViewerOutcome.failed,
  };
}
