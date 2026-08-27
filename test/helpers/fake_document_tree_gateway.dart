import 'dart:io';

import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:helm/features/files/domain/download_destination.dart';

/// Scripted stand-in for the Storage Access Framework.
///
/// Mirrors [FakeSftpSession]'s role for [SftpSession]: the
/// [DocumentTreeGateway] seam exists precisely so tests never need a
/// device, and this is the fake that fills it.
///
/// Calls are RECORDED, not just answered, so a test can assert on what was
/// never done — that a publish into a revoked folder copies nothing, that
/// clearing a folder gives its grant back — as well as on what came back.
class FakeDocumentTreeGateway implements DocumentTreeGateway {
  FakeDocumentTreeGateway({
    this.picks,
    this.writeGrant = true,
    this.folderPresent = true,
    this.copyError,
  });

  /// What the picker returns. Null models the user declining.
  final DownloadDestination? picks;

  /// What [hasWriteGrant] answers. False models a revoked or wiped grant.
  bool writeGrant;

  /// What [folderExists] answers. False models a deleted folder.
  bool folderPresent;

  /// Thrown by every [copyInto] call.
  Object? copyError;

  /// Names already taken in the destination, so a test can exercise a
  /// collision without a filesystem. A requested name in here is served
  /// under a derived one, exactly as the platform's no-overwrite contract
  /// does.
  final existingNames = <String>{};

  final pickedWith = <String?>[];
  final copiedNames = <String>[];
  final copiedSources = <File>[];
  final releasedUris = <String>[];

  var pickCalls = 0;

  @override
  Future<DownloadDestination?> pickFolder({String? initialUri}) async {
    pickCalls++;
    pickedWith.add(initialUri);
    return picks;
  }

  @override
  Future<bool> hasWriteGrant(String uri) async => writeGrant;

  @override
  Future<bool> folderExists(String uri) async => folderPresent;

  @override
  Future<PublishedFile> copyInto({
    required File source,
    required String treeUri,
    required String fileName,
  }) async {
    final error = copyError;
    if (error != null) throw error;

    copiedSources.add(source);
    copiedNames.add(fileName);

    // Mints `report(1).docx` from `report.docx`, matching what a document
    // provider does when asked not to overwrite.
    final name = existingNames.contains(fileName)
        ? _derive(fileName)
        : fileName;
    existingNames.add(name);
    return PublishedFile(uri: Uri.parse('$treeUri/$name'), name: name);
  }

  @override
  Future<void> releaseFolder(String uri) async => releasedUris.add(uri);

  static String _derive(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) return '$fileName(1)';
    return '${fileName.substring(0, dot)}(1)${fileName.substring(dot)}';
  }
}
