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
    this.filePick,
    this.mediaPick,
    this.fileContents = const {},
    this.readChunkSize,
    this.readChunkGap = Duration.zero,
  });

  /// What the picker returns. Null models the user declining.
  final DownloadDestination? picks;

  /// What [pickFile] returns. Null models the user declining an upload
  /// pick, exactly as [picks] models declining a folder pick.
  PickedDocument? filePick;

  /// Scripted media selection; null models cancellation.
  List<PickedDocument>? mediaPick;
  var pickMediaCalls = 0;

  @override
  Future<List<PickedDocument>?> pickMedia() async {
    pickMediaCalls++;
    return mediaPick;
  }

  /// Bytes [readFile] streams back, keyed by [PickedDocument.uri]. A URI
  /// absent here answers with an error, mirroring [FakeSftpSession.files]
  /// refusing an unregistered path rather than pretending one exists.
  final Map<String, List<int>> fileContents;

  /// Splits each entry in [fileContents] into chunks of this size before
  /// yielding, mirroring what a real SAF stream does for anything larger
  /// than one buffer — and the only way a test can observe more than one
  /// upload progress step, or cancel mid-transfer, without a real device.
  /// Null streams the whole entry as a single chunk.
  final int? readChunkSize;

  /// Delay before each chunk [readFile] yields, for exercising a
  /// cancellation that must land between chunks rather than before the
  /// stream starts or after it finishes — the same role
  /// [FakeRemoteFile.chunkGap] plays for a download.
  final Duration readChunkGap;

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

  var pickFileCalls = 0;
  final readUris = <String>[];
  Object? readError;

  @override
  Future<PickedDocument?> pickFile() async {
    pickFileCalls++;
    return filePick;
  }

  @override
  Stream<List<int>> readFile(String uri) async* {
    readUris.add(uri);
    final error = readError;
    if (error != null) throw error;
    final content = fileContents[uri];
    if (content == null) {
      throw StateError('FakeDocumentTreeGateway has no content for $uri');
    }

    final size = readChunkSize;
    if (size == null) {
      yield content;
      return;
    }

    for (var start = 0; start < content.length; start += size) {
      if (readChunkGap > Duration.zero) {
        await Future<void>.delayed(readChunkGap);
      }
      final end = (start + size).clamp(0, content.length);
      yield content.sublist(start, end);
    }
  }

  static String _derive(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) return '$fileName(1)';
    return '${fileName.substring(0, dot)}(1)${fileName.substring(dot)}';
  }
}
