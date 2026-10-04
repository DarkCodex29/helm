import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';

/// The app's [KnownHostsService], exposed for override: tests inject one
/// backed by a fake store instead of touching platform secure storage,
/// the same seam `sessionHoldControllerProvider` offers one layer up.
final knownHostsServiceProvider = Provider<KnownHostsService>(
  (_) => KnownHostsService(),
);

/// Every host key pinned by this device, for the trusted-hosts view.
///
/// A plain [FutureProvider] rather than an [AsyncNotifier]: nothing in
/// this screen mutates the list in place. [forgetPinnedHost] goes straight
/// to [KnownHostsService.removeHost] and then [Ref.invalidate]s this
/// provider to re-read the store, the same reload-by-invalidation shape
/// `ProfilesNotifier.reload` uses one layer down.
final trustedHostsProvider = FutureProvider<List<PinnedHost>>((ref) async {
  return ref.read(knownHostsServiceProvider).listPinnedHosts();
});

/// Forgets one pinned host and refreshes [trustedHostsProvider].
///
/// A free function rather than a method on a notifier: there is no state
/// to own between calls, only a write followed by a provider refresh, and
/// [WidgetRef] already gives every caller both of the pieces this needs.
///
/// [keyType] is nullable because a legacy pin — see [PinnedHost.isLegacy]
/// — has none. [KnownHostsService.removeHost] still requires a non-null
/// [String], and this task must not change that contract, so a legacy
/// forget passes an empty string: no real SSH host key algorithm name is
/// empty, so the versioned delete this sends is guaranteed to be a no-op,
/// and the call still reaches the legacy delete `removeHost` always
/// performs — the entry this call actually needs to clear.
Future<void> forgetPinnedHost(
  WidgetRef ref, {
  required String host,
  required int port,
  required String? keyType,
}) async {
  await ref
      .read(knownHostsServiceProvider)
      .removeHost(host: host, port: port, keyType: keyType ?? '');
  ref.invalidate(trustedHostsProvider);
}
