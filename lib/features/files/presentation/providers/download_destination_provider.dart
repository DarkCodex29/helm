import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/files/data/document_tree_gateway.dart';
import 'package:helm/features/files/data/download_destination_service.dart';
import 'package:helm/features/files/data/download_destination_store.dart';
import 'package:helm/features/files/domain/download_destination.dart';

/// The live destination service.
///
/// A provider rather than a constructor argument threaded through the
/// sheet, because two unrelated places need the same instance: the
/// download flow, which publishes, and the folder control, which chooses.
/// Overridden wholesale in tests — [SafDocumentTreeGateway] reaches the
/// platform over a method channel a test host does not have.
final downloadDestinationServiceProvider = Provider<DownloadDestinationService>(
  (_) => DownloadDestinationService(
    store: DownloadDestinationStore(),
    gateway: SafDocumentTreeGateway(),
  ),
);

/// The folder downloads are currently kept in, or null for none.
///
/// An [AsyncNotifier] because the answer comes off disk, and because the
/// two things the user can do to it — choose and forget — both need to
/// re-publish it to everything watching. Null is a legitimate, settled
/// value here rather than an absence of data: it means "no folder", which
/// on iOS is permanent and on Android is the state before the first
/// choice.
class DownloadDestinationNotifier extends AsyncNotifier<DownloadDestination?> {
  @override
  Future<DownloadDestination?> build() =>
      ref.read(downloadDestinationServiceProvider).current();

  /// Whether this platform has a folder to offer at all.
  ///
  /// Read straight off the service rather than derived from [state], since
  /// "no folder chosen" and "no folder to choose" are both null and the UI
  /// has to tell them apart — one gets a picker, the other gets nothing.
  bool get supportsFolderChoice =>
      ref.read(downloadDestinationServiceProvider).supportsFolderChoice;

  /// Opens the picker and adopts whatever comes back.
  ///
  /// A declined picker leaves [state] exactly as it was. Nothing is set to
  /// loading first: the picker is a full-screen system dialog, so there is
  /// no moment where a spinner in this app would be visible, and blanking
  /// the current folder to show one would briefly claim there is none.
  Future<void> choose() async {
    final service = ref.read(downloadDestinationServiceProvider);
    final picked = await service.choose();
    if (picked == null) return;
    state = AsyncData(picked);
  }

  Future<void> forget() async {
    await ref.read(downloadDestinationServiceProvider).forget();
    state = const AsyncData(null);
  }

  /// Re-reads the folder from storage.
  ///
  /// Exists for one caller: a publish that discovered the grant or the
  /// folder itself was gone CLEARS the stored choice, so this state is
  /// stale the moment that happens. Without this the UI would keep naming
  /// a destination the app has already given up on.
  Future<void> refresh() async {
    state = AsyncData(
      await ref.read(downloadDestinationServiceProvider).current(),
    );
  }
}

final downloadDestinationProvider =
    AsyncNotifierProvider<DownloadDestinationNotifier, DownloadDestination?>(
      DownloadDestinationNotifier.new,
    );
