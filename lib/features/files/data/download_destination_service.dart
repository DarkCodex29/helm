import 'dart:io';

import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:helm/features/files/data/download_destination_store.dart';
import 'package:helm/features/files/domain/download_destination.dart';

/// Owns the folder the user keeps downloads in: choosing it, forgetting
/// it, and putting files into it.
///
/// ### One class rather than a picker and a publisher
///
/// These look like two concerns and are one, because a single rule spans
/// them: A DESTINATION THAT NO LONGER WORKS MUST BE FORGOTTEN. That rule
/// is discovered while publishing and acted on by the same code that owns
/// the choice, and splitting the two would mean two classes holding the
/// same store and gateway and having to agree about when a grant is dead.
/// One class means one place where that can be got wrong.
///
/// ### Publishing is not the download
///
/// Nothing here runs until a transfer has completed AND passed its length
/// check, so by construction the bytes are already on the device when any
/// of these methods is called. That is why every ending is a
/// [PublishOutcome] and none of them is a [DownloadFailure]: a file that
/// could not be copied into the user's folder is still a file they can
/// open, and reporting it as a failed download would be false.
class DownloadDestinationService {
  DownloadDestinationService({
    required DownloadDestinationStore store,
    required DocumentTreeGateway gateway,
    bool? supportsFolderChoice,
  }) : _store = store,
       _gateway = gateway,
       supportsFolderChoice = supportsFolderChoice ?? Platform.isAndroid;

  static final _log = HelmLogger('DownloadDestinationService');

  final DownloadDestinationStore _store;
  final DocumentTreeGateway _gateway;

  /// Whether this platform asks the user to nominate a folder at all.
  ///
  /// A CONSTRUCTOR PARAMETER, not a bare `Platform.isAndroid` at each use
  /// site, for the same reason [SftpDownloadService] takes a
  /// [DownloadDirectoryResolver]: the test host is neither platform, so a
  /// direct check would make the iOS path untestable and the Android path
  /// untested. The default still reads `Platform.isAndroid`, so production
  /// wiring needs to say nothing.
  ///
  /// False on iOS, and that is the whole platform difference in this
  /// slice — stated once, here, rather than repeated as a condition
  /// wherever a folder is mentioned. iOS needs no picker because
  /// `Documents/helm_downloads` is ALREADY the user's folder: the
  /// `Info.plist` keys added in slice 2a publish it to the Files app, so
  /// downloads land somewhere visible, persistent and reachable by other
  /// apps with no choice to make. Bolting a picker on for symmetry would
  /// add a question with no answer that improves anything.
  final bool supportsFolderChoice;

  /// The folder currently in use, or null if there is none.
  ///
  /// Always null where [supportsFolderChoice] is false, even if a value
  /// somehow survived in storage — a platform that cannot use a folder
  /// must never show one, or the UI would offer to change a setting that
  /// does nothing.
  Future<DownloadDestination?> current() async {
    if (!supportsFolderChoice) return null;
    return _store.read();
  }

  /// Asks the user for a folder and remembers it.
  ///
  /// Returns null when they decline, and a declined picker CHANGES
  /// NOTHING: backing out of the dialog is not a request to lose the
  /// folder already in use.
  Future<DownloadDestination?> choose() async {
    if (!supportsFolderChoice) return null;
    final picked = await _gateway.pickFolder();
    if (picked == null) return null;
    await _store.write(picked);
    return picked;
  }

  /// Stops using the current folder, and hands its grant back.
  ///
  /// The release is best-effort and the forgetting is not. The user asked
  /// to stop using this folder; a platform that will not take its grant
  /// back is no reason to leave them still pointed at it, so a failure
  /// there is logged and the stored value is cleared regardless.
  Future<void> forget() async {
    final existing = await _store.read();
    if (existing != null) {
      try {
        await _gateway.releaseFolder(existing.uri);
      } catch (error) {
        _log.w('Could not release the grant on ${existing.name}: $error');
      }
    }
    await _store.clear();
  }

  /// Copies [file] into the chosen folder and reports what happened.
  ///
  /// NEVER THROWS, matching [SftpDownloadService.download]: a caller here
  /// is always in the middle of reporting a SUCCESSFUL download, and an
  /// exception escaping into that path is how a publish failure turns into
  /// a failed transfer.
  Future<PublishOutcome> publish(File file) async {
    if (!supportsFolderChoice) return const PublishNotNeeded();

    final DownloadDestination? destination;
    try {
      destination = await _store.read();
    } catch (error) {
      _log.w('Could not read the chosen download folder: $error');
      return PublishFailed(PublishFailure.unknown, detail: '$error');
    }
    if (destination == null) return const PublishNotConfigured();

    // Checked BEFORE the copy rather than inferred from its failure. A
    // revoked grant and a full disk both surface as an exception from the
    // platform, and only one of them means the folder has to be chosen
    // again — asking first is the only way to tell them apart before
    // acting on either.
    try {
      if (!await _gateway.hasWriteGrant(destination.uri)) {
        // Cleared, NOT released: there is no grant left to hand back, and
        // asking the platform to release one it no longer has is a call
        // that can only fail. The folder is forgotten so the next download
        // reports [PublishNotConfigured] and the UI offers a fresh choice,
        // instead of repeating this same failure forever.
        _log.w('Lost the persisted grant on ${destination.name}');
        await _store.clear();
        return const PublishFailed(PublishFailure.permissionLost);
      }
    } catch (error) {
      _log.w('Could not check the grant on ${destination.name}: $error');
      return PublishFailed(PublishFailure.unknown, detail: '$error');
    }

    try {
      final published = await _gateway.copyInto(
        source: file,
        treeUri: destination.uri,
        fileName: _leafName(file.path),
      );
      return PublishedToFolder(
        folderName: destination.name,
        fileName: published.name,
        uri: published.uri,
      );
    } catch (error) {
      _log.w('Could not publish into ${destination.name}: $error');
      return _classifyCopyFailure(destination, error);
    }
  }

  // ── Private ──────────────────────────────────────────────────────────────

  /// Works out whether a failed copy means the folder is GONE or merely
  /// that this write did not fit.
  ///
  /// The existence check happens only on the failure path, so the ordinary
  /// download pays nothing for it.
  Future<PublishOutcome> _classifyCopyFailure(
    DownloadDestination destination,
    Object error,
  ) async {
    final bool present;
    try {
      present = await _gateway.folderExists(destination.uri);
    } catch (checkError) {
      // The platform could not even say whether the folder is there. That
      // is not enough to justify discarding the user's choice, so the
      // folder is kept and the failure reported as what it looked like.
      _log.w('Could not confirm ${destination.name} still exists: $checkError');
      return PublishFailed(PublishFailure.storage, detail: '$error');
    }

    if (!present) {
      // Forgotten for the same reason a lost grant is: the URI now names
      // nothing, so keeping it would only let the UI claim a destination
      // that cannot exist.
      await _store.clear();
      return PublishFailed(
        PublishFailure.destinationMissing,
        detail: '$error',
      );
    }

    // The folder is still there and the write did not land: out of space,
    // or the provider refused it. The choice is KEPT — a full disk is not
    // a reason to make the user pick a folder again.
    return PublishFailed(PublishFailure.storage, detail: '$error');
  }

  /// The final path component of [path].
  ///
  /// Taken from the STAGED file rather than from the remote entry's name,
  /// because staging already neutralised whatever the remote host called
  /// it (see `SftpDownloadService._stagedName`). Passing the remote name
  /// here would put a string the host chose back into a filename, undoing
  /// that.
  static String _leafName(String path) {
    final separator = path.lastIndexOf(Platform.pathSeparator);
    return separator < 0 ? path : path.substring(separator + 1);
  }
}
