import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/settings/presentation/settings_provider.dart';
import '../../helpers/fake_secure_storage.dart';
import 'package:helm/features/agentd/data/agentd_client.dart';
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

  group('reactivity', () {
    Future<ProviderContainer> live(FakeSecureStorage storage) async {
      final c = ProviderContainer(
        overrides: [agentdSecureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<AgentdClient?> client(ProviderContainer c) => c
        .read(agentdClientProvider('p1').future)
        .timeout(const Duration(seconds: 5));

    /// Observes closing: connect() makes the state flip, close() ends it.
    Future<void> expectClosed(AgentdClient old) async {
      old.connect(); // ignored when already closed
      expect(old.state, isA<AgentdDisconnected>());
      await expectLater(
        old.send('x'),
        throwsA(
          isA<AgentdCommandException>().having(
            (e) => e.kind,
            'kind',
            AgentdCommandError.closed,
          ),
        ),
      );
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({
        AppConstants.profilesStorageKey: [_profileJson('127.0.0.1')],
      });
    });

    test('provisioning a new token rebuilds the client and closes the old '
        'one', () async {
      final storage = FakeSecureStorage();
      final c = await live(storage);
      final store = c.read(agentdTokenStoreProvider);
      expect(await client(c), isNull);
      await store.write('p1', _token);
      final first = (await client(c))!;
      await store.write('p1', _token2);
      final second = (await client(c))!;
      expect(identical(first, second), isFalse);
      await expectClosed(first);
      expect(second.state, isA<AgentdDisconnected>());
    });

    test(
      'deleting the token resolves to null and closes the old one',
      () async {
        final storage = FakeSecureStorage();
        final c = await live(storage);
        final store = c.read(agentdTokenStoreProvider);
        await store.write('p1', _token);
        final old = (await client(c))!;
        await store.delete('p1');
        expect(await client(c), isNull);
        await expectClosed(old);
      },
    );

    test('changing the profile host rebuilds the client', () async {
      final storage = FakeSecureStorage({
        AgentdTokenStore.storageKey('p1'): _token,
      });
      final c = await live(storage);
      final old = (await client(c))!;
      expect(old.endpoint.host, '127.0.0.1');
      await ConnectionProfileRepository().update(
        ConnectionProfile.fromJson(_profileMap('10.9.9.9')),
      );
      c.invalidate(profilesProvider); // what the edit screen does
      final fresh = (await client(c))!;
      expect(fresh.endpoint.host, '10.9.9.9');
      expect(identical(old, fresh), isFalse);
      await expectClosed(old);
    });
  });
}

const _token2 = 'GHIJghijGHIJghijGHIJghijGHIJghijGHIJghijGHI';

Map<String, dynamic> _profileMap(String host) => {
  'id': 'p1',
  'name': 'Test',
  'host': host,
  'port': 22,
  'username': 'someone',
};

String _profileJson(String host) => jsonEncode(_profileMap(host));
