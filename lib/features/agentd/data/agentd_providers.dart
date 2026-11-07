import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:helm/features/agentd/data/agentd_client.dart';
import 'package:helm/features/agentd/data/agentd_token_store.dart';
import 'package:helm/features/agentd/domain/agentd_endpoint.dart';
import 'package:helm/features/settings/presentation/settings_provider.dart';

/// The keystore behind the token store. Overridable in tests.
final agentdSecureStorageProvider = Provider<FlutterSecureStorage>(
  (_) => const FlutterSecureStorage(),
);

/// Bumped whenever the token of a profile is written or deleted, so the
/// client built from the old value is rebuilt (and closed).
final agentdTokenVersionProvider = StateProvider.family<int, String>(
  (_, profileId) => 0,
);

final agentdTokenStoreProvider = Provider<AgentdTokenStore>(
  (ref) => AgentdTokenStore(
    storage: ref.watch(agentdSecureStorageProvider),
    onChanged: (profileId) {
      ref.read(agentdTokenVersionProvider(profileId).notifier).state++;
    },
  ),
);

/// Where the daemon of a profile listens: the profile's host (the same Mac,
/// reached over the tailnet) on the daemon's default port. Null when the
/// profile no longer exists. Overridable in tests.
final agentdEndpointProvider = FutureProvider.family<AgentdEndpoint?, String>((
  ref,
  profileId,
) async {
  // Watching the profile list: an edit (the screen invalidates it) rebuilds.
  final profiles = await ref.watch(profilesProvider.future);
  for (final p in profiles) {
    if (p.id == profileId) return AgentdEndpoint(host: p.host);
  }
  return null;
});

/// The [AgentdClient] of one profile, built from its endpoint and the
/// token in the keystore, and closed when the provider is disposed.
///
/// Resolves to null when the profile or its token is missing (the caller
/// shows "no token yet"). The client is NOT connected here: whoever uses it
/// calls [AgentdClient.connect].
final agentdClientProvider = FutureProvider.family<AgentdClient?, String>((
  ref,
  profileId,
) async {
  final endpoint = await ref.watch(agentdEndpointProvider(profileId).future);
  // A token write/delete bumps this and rebuilds; onDispose closes the old.
  ref.watch(agentdTokenVersionProvider(profileId));
  if (endpoint == null) return null;
  final token = await ref.watch(agentdTokenStoreProvider).read(profileId);
  if (token == null || token.isEmpty) return null;
  final client = AgentdClient(endpoint: endpoint, token: token);
  ref.onDispose(client.close);
  return client;
});
