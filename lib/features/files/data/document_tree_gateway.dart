import 'dart:io';

import 'package:helm/features/files/domain/download_destination.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';

/// A file this app placed in the user's folder.
class PublishedFile {
  const PublishedFile({required this.uri, required this.name});

  final Uri uri;

  /// The name the platform actually gave it. See
  /// [PublishedToFolder.fileName] for the two ways this diverges from the
  /// name that was requested.
  final String name;
}

/// Everything this app does with a user-chosen storage tree.
///
/// An interface rather than direct plugin calls, for the same reason
/// [ExternalViewer] wraps `open_filex`: both `saf_util` and `saf_stream`
/// reach the platform over a method channel that does not exist in a unit
/// test, so a test host cannot run a single line of them. This is the seam
/// that lets every DECISION built on top of them — when a grant counts as
/// lost, what a name collision does, whether a publish failure may be
/// reported as a download failure — be tested without a device.
///
/// It is also the containment boundary. THIS IS THE ONLY FILE IN THE APP
/// THAT IMPORTS EITHER PLUGIN, so replacing them is a change to one file,
/// and the pinned versions in `pubspec.yaml` cannot leak their types into
/// the domain.
abstract interface class DocumentTreeGateway {
  /// Asks the user to nominate a folder, returning null if they decline.
  ///
  /// [initialUri] is where the picker opens, and is a hint the platform is
  /// free to ignore.
  Future<DownloadDestination?> pickFolder({String? initialUri});

  /// Whether this app still holds a persisted WRITE grant on [uri].
  Future<bool> hasWriteGrant(String uri);

  /// Whether the folder [uri] names still exists.
  Future<bool> folderExists(String uri);

  /// Copies [source] into the folder [treeUri] names.
  ///
  /// NEVER OVERWRITES. A name already in use produces a new file under a
  /// derived name, reported back in [PublishedFile.name] — see
  /// [SafDocumentTreeGateway.copyInto] for why that is the right way round.
  Future<PublishedFile> copyInto({
    required File source,
    required String treeUri,
    required String fileName,
  });

  /// Gives back the persisted grant on [uri].
  ///
  /// Called when the user clears their chosen folder. Forgetting the URI
  /// without this would leave the grant in the system's permission table
  /// forever, so the app would still appear in the folder's access list
  /// having deliberately given up the ability to use it.
  Future<void> releaseFolder(String uri);
}

/// The real gateway, over `saf_util` and `saf_stream`.
///
/// ### Android only
///
/// Both plugins are no-ops off Android — the Storage Access Framework has
/// no counterpart elsewhere. Nothing here checks the platform, because
/// nothing here is reached off Android: [DownloadPublisher] decides that,
/// in one place, and this class would simply fail if it were called
/// anyway.
class SafDocumentTreeGateway implements DocumentTreeGateway {
  SafDocumentTreeGateway({SafUtil? util, SafStream? stream})
    : _util = util ?? SafUtil(),
      _stream = stream ?? SafStream();

  final SafUtil _util;
  final SafStream _stream;

  /// Where the folder picker opens.
  ///
  /// The device's Downloads folder, which is where somebody looking for a
  /// file they just downloaded would look first.
  ///
  /// IT CANNOT ITSELF BE CHOSEN, and that is a platform rule rather than
  /// an oversight: from Android 11, `ACTION_OPEN_DOCUMENT_TREE` refuses
  /// the `Download` directory along with the roots of internal and SD-card
  /// storage (developer.android.com/about/versions/11/privacy/storage —
  /// "Access to directories"). The picker still SHOWS it, with its confirm
  /// button greyed out. Seeding here is therefore worth doing and worth
  /// explaining: it puts the user one step from a sensible answer — a
  /// subfolder of Downloads, existing or created in the picker — and the
  /// prompt that leads here has to say "a folder inside it" rather than
  /// let them meet a dead button with no account of why.
  static const downloadsUri =
      'content://com.android.externalstorage.documents/document/primary%3ADownload';

  @override
  Future<DownloadDestination?> pickFolder({String? initialUri}) async {
    final picked = await _util.pickDirectory(
      initialUri: initialUri ?? downloadsUri,
      // Both true, and both are the point of the call. `writePermission`
      // is what the copy needs; `persistablePermission` is what makes the
      // grant outlive this process, which is the difference between
      // asking once and asking on every single download.
      writePermission: true,
      persistablePermission: true,
    );
    if (picked == null) return null;
    return DownloadDestination(uri: picked.uri, name: picked.name);
  }

  @override
  Future<bool> hasWriteGrant(String uri) =>
      _util.hasPersistedPermission(uri, checkRead: true, checkWrite: true);

  @override
  Future<bool> folderExists(String uri) => _util.exists(uri, true);

  @override
  Future<PublishedFile> copyInto({
    required File source,
    required String treeUri,
    required String fileName,
  }) async {
    final created = await _stream.pasteLocalFile(
      source.path,
      treeUri,
      fileName,
      _mimeFor(fileName),
      // NEVER OVERWRITE, which is the opposite of what the app-private
      // staging directory does, and deliberately so.
      //
      // Staging is this app's scratch space, where last-write-wins is
      // correct: re-fetching a file the agent has rewritten must show the
      // new one. This folder belongs to the USER. A `report.docx` already
      // sitting in it may well be theirs and have nothing to do with
      // Helm, and the two mistakes are not symmetric — overwriting
      // destroys something unrecoverable, while declining to leaves
      // clutter they can delete. The reversible mistake wins.
      //
      // The platform then mints a free name (`report(1).docx`) and returns
      // it, which is why [PublishedFile.name] carries what was created
      // rather than what was asked for.
      overwrite: false,
    );
    return PublishedFile(
      uri: created.uri,
      // `fileName` is nullable in `SafNewFile` because the provider is not
      // obliged to report a display name. Falling back to the requested
      // name is the closest true statement available; it is only ever
      // wrong in the collision case, where it under-reports rather than
      // inventing something.
      name: created.fileName ?? fileName,
    );
  }

  @override
  Future<void> releaseFolder(String uri) =>
      _util.releasePersistedPermission(uri, read: true, write: true);

  /// A MIME type for [fileName], chosen to AGREE WITH ITS EXTENSION.
  ///
  /// This is not decoration and it is not for the benefit of a viewer.
  /// `saf_stream` creates the file with `DocumentFile.createFile(mime,
  /// name)` (`SafStreamPlugin.kt:407-411`), and Android's document
  /// providers append the MIME type's canonical extension to the display
  /// name when it disagrees with the one already there. Handing
  /// `application/octet-stream` to a file called `report.docx` is how a
  /// download silently lands as `report.docx.bin`.
  ///
  /// A SHORTLIST, not a registry, and knowingly so: it covers what somebody
  /// pulls off a development machine — documents, archives, images, and
  /// the text formats source code arrives in. An extension outside it
  /// falls through to `application/octet-stream` and may well pick up a
  /// `.bin` suffix. That is survivable ONLY because
  /// [PublishedFile.name] reports the name the file really got, so the
  /// worst case is an ugly name the user can see, never a file they cannot
  /// find.
  static String _mimeFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) {
      return 'application/octet-stream';
    }
    final extension = fileName.substring(dot + 1).toLowerCase();
    return _mimeByExtension[extension] ?? 'application/octet-stream';
  }

  static const _mimeByExtension = <String, String>{
    // Documents
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx':
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx':
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'odt': 'application/vnd.oasis.opendocument.text',
    'ods': 'application/vnd.oasis.opendocument.spreadsheet',
    'rtf': 'application/rtf',
    'epub': 'application/epub+zip',
    // Text and the shapes source code arrives in
    'txt': 'text/plain',
    'md': 'text/markdown',
    'csv': 'text/csv',
    'log': 'text/plain',
    'json': 'application/json',
    'xml': 'text/xml',
    'yaml': 'text/plain',
    'yml': 'text/plain',
    'html': 'text/html',
    'htm': 'text/html',
    'css': 'text/css',
    'js': 'text/javascript',
    'dart': 'text/plain',
    'py': 'text/x-python',
    'sh': 'text/x-sh',
    'sql': 'text/plain',
    // Images
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'svg': 'image/svg+xml',
    'heic': 'image/heic',
    // Archives
    'zip': 'application/zip',
    'gz': 'application/gzip',
    'tar': 'application/x-tar',
    'bz2': 'application/x-bzip2',
    '7z': 'application/x-7z-compressed',
    // Media
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
    'm4a': 'audio/mp4',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
  };
}
