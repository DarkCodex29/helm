import 'dart:io';

import 'package:flutter/services.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:helm/features/files/domain/download_destination.dart';

/// The channel `DocumentPickerPlugin.swift` answers on.
///
/// Duplicated in that file as `CHANNEL`, and the two MUST stay equal.
const String kDocumentPickerMethodChannel = 'helm/document_picker';

/// The real [DocumentTreeGateway] on iOS, over `DocumentPickerPlugin.swift`.
///
/// ### iOS has no Storage Access Framework, and therefore no folder
///
/// Everything [SafDocumentTreeGateway] does with a persisted, re-openable
/// folder grant is an Android concept with no iOS counterpart: there is no
/// system picker that hands back a writable tree the app can keep using
/// across launches, and iOS sandboxes an app's own container well enough
/// that nothing like it is needed for downloads — see
/// `DownloadDestinationService.supportsFolderChoice`, which is the single
/// place that decides iOS never asks for one. [pickFolder], [hasWriteGrant],
/// [folderExists], [copyInto] and [releaseFolder] are therefore UNREACHABLE
/// here, and each throws [UnsupportedError] naming that guard rather than
/// returning a fake success. A fake success (an empty `PublishedFile`, a
/// `true` write grant that never existed) would let some future caller —
/// one who never read this comment — believe a file had been published
/// into a folder that was never offered. A loud throw is the only answer
/// that cannot be misread.
///
/// ### Picking a file is still possible, and still worth a gateway
///
/// Uploading does not need a persisted folder grant; it needs ONE local
/// file, read ONCE, for the lifetime of a single upload. `asCopy: true` on
/// the native document picker (see `DocumentPickerPlugin.swift`) hands back
/// exactly that: a copy already inside the app's own container, so there is
/// no security-scoped URL to keep alive and no permission to persist.
/// [pickFile] and [pickMedia] are the two operations [UploadSourcePicker]
/// actually calls on iOS, and this class answers both the same shape
/// [SafDocumentTreeGateway] does, so [SafUploadSource] needs no iOS variant
/// of its own.
class IosDocumentTreeGateway implements DocumentTreeGateway {
  IosDocumentTreeGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kDocumentPickerMethodChannel);

  static final _log = HelmLogger('IosDocumentTreeGateway');

  final MethodChannel _channel;

  /// The reason every folder operation below refuses to run.
  ///
  /// Named once so every throw can point at it with one message rather
  /// than five slightly different explanations.
  static const _noFolderChoice =
      'DownloadDestinationService.supportsFolderChoice is false on iOS: '
      'there is no SAF-equivalent folder grant to pick, check, write into, '
      'or release here.';

  @override
  Future<DownloadDestination?> pickFolder({String? initialUri}) {
    throw UnsupportedError(_noFolderChoice);
  }

  @override
  Future<bool> hasWriteGrant(String uri) {
    throw UnsupportedError(_noFolderChoice);
  }

  @override
  Future<bool> folderExists(String uri) {
    throw UnsupportedError(_noFolderChoice);
  }

  @override
  Future<PublishedFile> copyInto({
    required File source,
    required String treeUri,
    required String fileName,
  }) {
    throw UnsupportedError(_noFolderChoice);
  }

  @override
  Future<void> releaseFolder(String uri) {
    throw UnsupportedError(_noFolderChoice);
  }

  @override
  Future<PickedDocument?> pickFile() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'pickFile',
      );
      if (result == null) return null;
      return _toPickedDocument(result);
    } on MissingPluginException {
      // No native side registered to answer. Exactly as
      // `ForegroundServiceHost` treats this on a platform without one: not
      // a fault, just nothing to pick.
      _log.i('No document picker plugin registered; nothing to pick');
      return null;
    } on PlatformException catch (error) {
      // A cancelled pick never reaches here — the native side replies nil
      // for that, never an error (see `DocumentPickerPlugin.swift`). What
      // lands here is a genuine platform refusal (for example a second
      // concurrent pick, `ALREADY_PICKING`), and it means the same thing
      // to this call's caller as a decline does: there is nothing to
      // upload.
      _log.w('Platform refused the file pick: ${error.code} ${error.message}');
      return null;
    }
  }

  @override
  Future<List<PickedDocument>?> pickMedia() async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>('pickMedia');
      if (result == null) return null;
      return result
          .cast<Map<Object?, Object?>>()
          .map(_toPickedDocument)
          .toList();
    } on MissingPluginException {
      _log.i('No document picker plugin registered; nothing to pick');
      return null;
    } on PlatformException catch (error) {
      _log.w('Platform refused the media pick: ${error.code} ${error.message}');
      return null;
    }
  }

  /// Streams the bytes of [uri], which on iOS is a LOCAL FILE PATH rather
  /// than the content URI [DocumentTreeGateway.readFile]'s own doc comment
  /// is written against. No plugin call is needed here, unlike
  /// [SafDocumentTreeGateway.readFile]: by the time a [PickedDocument]
  /// exists, `DocumentPickerPlugin.swift` has already copied the pick into
  /// this app's own temporary directory, so it is an ordinary file this
  /// process owns outright and `dart:io` can read directly.
  @override
  Stream<List<int>> readFile(String uri) => File(uri).openRead();

  static PickedDocument _toPickedDocument(Map<Object?, Object?> map) {
    return PickedDocument(
      uri: map['path'] as String,
      name: map['name'] as String,
      length: map['length'] as int,
    );
  }
}
