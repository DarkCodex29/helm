import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/agentd/data/agentd_client.dart';
import 'package:helm/features/agentd/data/agentd_token_store.dart';
import 'package:helm/features/agentd/domain/agentd_endpoint.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';

final agentdTokenStoreProvider = Provider<AgentdTokenStore>(
  (_) => AgentdTokenStore(),
);

/// Where the daemon of a profile listens: the profile's host (the same Mac,
/// reached over the tailnet) on the daemon's default port. Null when the
/// profile no longer exists. Overridable in tests.
final agentdEndpointProvider = FutureProvider.family<AgentdEndpoint?, String>((
  ref,
  profileId,
) async {
  final profile = await ConnectionProfileRepository().getById(profileId);
  return profile == null ? null : AgentdEndpoint(host: profile.host);
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
  if (endpoint == null) return null;
  final token = await ref.watch(agentdTokenStoreProvider).read(profileId);
  if (token == null || token.isEmpty) return null;
  final client = AgentdClient(endpoint: endpoint, token: token);
  ref.onDispose(client.close);
  return client;
});
