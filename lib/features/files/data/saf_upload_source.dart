import 'dart:io';

import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';

/// A local file the user picked, adapted to [UploadSource].
///
/// This is the caller [UploadSource]'s own doc comment named as missing:
/// a fully-wired source over a Storage Access Framework pick, so a widget
/// can hand [SftpUploadService] a file chosen through the platform's
/// document picker without importing `saf_util`/`saf_stream` itself. Both
/// methods are thin forwards to [DocumentTreeGateway] \u2014 the actual
/// platform reach is confined there, same as [SafDocumentTreeGateway]
/// documents for every other SAF operation.
class SafUploadSource implements UploadSource {
  SafUploadSource(this._gateway, this._document);

  final DocumentTreeGateway _gateway;
  final PickedDocument _document;

  /// The name to upload under \u2014 what the user picked, not a server path.
  String get name => _document.name;

  @override
  Future<int> length() async => _document.length;

  @override
  Stream<List<int>> openRead() => _gateway.readFile(_document.uri);
}

/// Picks a local file for upload, and says whether this platform can.
///
/// A SEPARATE class rather than a method the sheet calls on
/// [DocumentTreeGateway] directly, for the reason
/// [DownloadDestinationService.supportsFolderChoice] documents for its own
/// constructor parameter: the platform check has to live in ONE place a
/// test can drive both branches of, not a bare `Platform.isAndroid` at the
/// button's build site, where only the branch the test host happens to run
/// on would ever execute.
///
/// SAF \u2014 and therefore picking a file to upload \u2014 is Android only. iOS
/// gets NO upload control at all rather than one with a single, permanent
/// outcome: a button that always fails is worse than no button, the same
/// trade [SafDocumentTreeGateway]'s class comment makes for the gateway
/// itself.
class UploadSourcePicker {
  UploadSourcePicker({
    required DocumentTreeGateway gateway,
    bool? supportsPicking,
  }) : _gateway = gateway,
       supportsPicking = supportsPicking ?? Platform.isAndroid;

  final DocumentTreeGateway _gateway;

  /// Whether this platform can pick a local file to upload at all.
  final bool supportsPicking;

  /// Opens the system file picker and adapts whatever was chosen.
  ///
  /// Null off a platform that cannot pick, and null for a picker the user
  /// dismissed without choosing anything \u2014 the two are indistinguishable
  /// to a caller, and correctly so: both mean "there is nothing to
  /// upload", and neither is a failure worth reporting.
  Future<SafUploadSource?> pick() async {
    if (!supportsPicking) return null;
    final picked = await _gateway.pickFile();
    if (picked == null) return null;
    return SafUploadSource(_gateway, picked);
  }
}
