import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/agentd/data/agentd_providers.dart';
import 'package:helm/features/agentd/data/agentd_token_store.dart';
import 'package:helm/features/agentd/domain/agentd_connection_state.dart';
import 'package:helm/features/agentd/domain/agentd_endpoint.dart';

const _token = 'FAKEfakeFAKEfakeFAKEfakeFAKEfakeFAKEfakeFAK';

class _MemStorage extends FlutterSecureStorage {
  _MemStorage(this.data);
  final Map<String, String> data;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];
}

ProviderContainer _container(Map<String, String> store, AgentdEndpoint? ep) {
  final c = ProviderContainer(
    overrides: [
      agentdTokenStoreProvider.overrideWithValue(
        AgentdTokenStore(storage: _MemStorage(store)),
      ),
      agentdEndpointProvider.overrideWith((ref, id) async => ep),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  const ep = AgentdEndpoint(host: '127.0.0.1', port: 1);

  test('builds a client from the endpoint and the stored token', () async {
    final c = _container({AgentdTokenStore.storageKey('p1'): _token}, ep);
    final client = await c
        .read(agentdClientProvider('p1').future)
        .timeout(const Duration(seconds: 5));
    expect(client, isNotNull);
    expect(client!.endpoint, ep);
    expect(client.state, isA<AgentdDisconnected>());
    expect(client.toString(), isNot(contains(_token)));
  });

  test('one client per profile id', () async {
    final c = _container({
      AgentdTokenStore.storageKey('p1'): _token,
      AgentdTokenStore.storageKey('p2'): _token,
    }, ep);
    final a = await c.read(agentdClientProvider('p1').future);
    final b = await c.read(agentdClientProvider('p2').future);
    expect(identical(a, b), isFalse);
    expect(await c.read(agentdClientProvider('p1').future), same(a));
  });

  test('no token or no profile gives null', () async {
    final noToken = _container({}, ep);
    expect(await noToken.read(agentdClientProvider('p1').future), isNull);
    final noProfile = _container({
      AgentdTokenStore.storageKey('p1'): _token,
    }, null);
    expect(await noProfile.read(agentdClientProvider('p1').future), isNull);
  });

  test('disposing the container closes the client', () async {
    final storage = {AgentdTokenStore.storageKey('p1'): _token};
    final c = ProviderContainer(
      overrides: [
        agentdTokenStoreProvider.overrideWithValue(
          AgentdTokenStore(storage: _MemStorage(storage)),
        ),
        agentdEndpointProvider.overrideWith((ref, id) async => ep),
      ],
    );
    final client = (await c.read(agentdClientProvider('p1').future))!;
    final closed = client.states.firstWhere((s) => s is AgentdDisconnected);
    client.connect(); // makes close observable (state flips to connecting)
    c.dispose();
    await closed.timeout(const Duration(seconds: 5));
    client.connect(); // final: ignored
    expect(client.state, isA<AgentdDisconnected>());
  });
}
