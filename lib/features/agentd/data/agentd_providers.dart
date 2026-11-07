import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:helm/features/agentd/data/agentd_client.dart';
import 'package:helm/features/agentd/data/agentd_token_store.dart';
import 'package:helm/features/agentd/domain/agentd_connection_state.dart';
import 'package:helm/features/agentd/domain/agentd_endpoint.dart';
import 'package:helm/features/agentd/domain/agentd_tab_state.dart';
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

/// How an [AgentdClient] is built from an endpoint and token. Overridable in
/// tests (to observe or fake the client); production uses the real client.
typedef AgentdClientFactory =
    AgentdClient Function(AgentdEndpoint endpoint, String token);

final agentdClientFactoryProvider = Provider<AgentdClientFactory>(
  (_) =>
      (endpoint, token) => AgentdClient(endpoint: endpoint, token: token),
);

/// The [AgentdClient] of one profile, built from its endpoint and the
/// token in the keystore, and closed when the provider is disposed (it is
/// autoDispose: the socket closes when the last tab of the profile is gone).
///
/// Resolves to null when the profile or its token is missing (the caller
/// shows "no token yet"). The client is NOT connected here: whoever uses it
/// calls [AgentdClient.connect].
final agentdClientProvider = FutureProvider.autoDispose
    .family<AgentdClient?, String>((ref, profileId) async {
      // Registered before any await: a provider disposed mid-build must not
      // construct (or leak) a client, nor call onDispose on a dead ref.
      var disposed = false;
      ref.onDispose(() => disposed = true);
      final endpoint = await ref.watch(
        agentdEndpointProvider(profileId).future,
      );
      if (disposed) return null;
      // A token write/delete bumps this and rebuilds; onDispose closes the old.
      ref.watch(agentdTokenVersionProvider(profileId));
      if (endpoint == null) return null;
      final token = await ref.watch(agentdTokenStoreProvider).read(profileId);
      if (disposed) return null;
      if (token == null || token.isEmpty) return null;
      final client = ref.read(agentdClientFactoryProvider)(endpoint, token);
      ref.onDispose(client.close);
      return client;
    });

/// Connection state of a profile's daemon. ONE connection per profile, shared
/// by all its tabs; connects when first listened to and closes (through
/// [agentdClientProvider]) when the last listener goes.
///
/// Background: iOS suspends the socket while the app is backgrounded; the
/// client notices the drop and reconnects with backoff on resume, so no
/// lifecycle disconnect logic is added here.
final agentdClientStatesProvider = StreamProvider.autoDispose
    .family<AgentdConnectionState, String>((ref, profileId) {
      final out = StreamController<AgentdConnectionState>();
      ref.onDispose(out.close);
      () async {
        final client = await ref.watch(agentdClientProvider(profileId).future);
        if (out.isClosed) return;
        if (client == null) {
          out.add(const AgentdDisconnected());
          return;
        }
        final sub = client.states.listen((s) {
          if (!out.isClosed) out.add(s);
        });
        ref.onDispose(sub.cancel);
        if (!out.isClosed) out.add(client.state);
        client.connect();
      }().catchError((Object _) {
        // Token store/profile failures: stay on Absent (loading/disconnected).
        if (!out.isClosed) out.add(const AgentdDisconnected());
      });
      return out.stream;
    });

/// The tab-strip view of [agentdClientStatesProvider]. Loading is Absent.
final agentdTabStateProvider = Provider.autoDispose
    .family<AgentdTabState, String>(
      (ref, profileId) =>
          agentdTabStateFor(ref.watch(agentdClientStatesProvider(profileId))),
    );
