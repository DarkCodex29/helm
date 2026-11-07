@Timeout(Duration(seconds: 30))
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/agentd/data/agentd_client.dart';
import 'package:helm/features/agentd/data/agentd_providers.dart';
import 'package:helm/features/agentd/data/agentd_token_store.dart';
import 'package:helm/features/agentd/domain/agentd_connection_state.dart';
import 'package:helm/features/agentd/domain/agentd_endpoint.dart';
import 'package:helm/features/files/data/sftp_file_service.dart';

import '../../helpers/fake_secure_storage.dart';
import '../../helpers/fake_sftp_session.dart';
import 'support/fakes.dart';

const _token = 'FAKEfakeFAKEfakeFAKEfakeFAKEfakeFAKEfakeFAK';

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeConnector connector;
  late List<AgentdClient> built;
  late ProviderContainer c;

  setUp(() {
    connector = FakeConnector();
    built = [];
    c = ProviderContainer(
      overrides: [
        agentdClientProvider.overrideWith((ref, id) async {
          final client = AgentdClient(
            endpoint: const AgentdEndpoint(host: '127.0.0.1', port: 1),
            token: _token,
            connect: connector.call,
          );
          built.add(client);
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    addTearDown(c.dispose);
  });

  test(
    'the states provider connects the client once and streams states',
    () async {
      final seen = <AgentdConnectionState>[];
      c.listen(agentdClientStatesProvider('p1'), (_, n) {
        final v = n.valueOrNull;
        if (v != null) seen.add(v);
      });
      await settle();
      expect(built, hasLength(1));
      expect(connector.channels, hasLength(1));
      expect(seen, contains(isA<AgentdConnecting>()));
    },
  );

  test(
    'two consumers of one profile share one client and one socket',
    () async {
      c.listen(agentdClientStatesProvider('p1'), (_, _) {});
      c.listen(agentdClientStatesProvider('p1'), (_, _) {});
      await settle();
      expect(built, hasLength(1));
      expect(connector.channels, hasLength(1));
    },
  );

  test('dropping the last consumer closes the client and its socket', () async {
    final sub = c.listen(agentdClientStatesProvider('p1'), (_, _) {});
    await settle();
    expect(connector.last.closedByClient, isFalse);

    sub.close();
    await settle();

    expect(connector.last.closedByClient, isTrue);
    await expectLater(
      built.single.send('x').timeout(const Duration(seconds: 5)),
      throwsA(isA<AgentdCommandException>()),
    );
  });

  test(
    'a null client (no token) yields Disconnected and never connects',
    () async {
      final none = ProviderContainer(
        overrides: [agentdClientProvider.overrideWith((ref, id) async => null)],
      );
      addTearDown(none.dispose);
      final seen = <AgentdConnectionState>[];
      none.listen(agentdClientStatesProvider('p1'), (_, n) {
        final v = n.valueOrNull;
        if (v != null) seen.add(v);
      });
      await settle();
      expect(seen, [isA<AgentdDisconnected>()]);
    },
  );

  test('agentdClientProvider is released when nobody listens', () async {
    final real = ProviderContainer(
      overrides: [
        agentdSecureStorageProvider.overrideWithValue(
          FakeSecureStorage({AgentdTokenStore.storageKey('p1'): _token}),
        ),
        agentdEndpointProvider.overrideWith(
          (ref, id) async => const AgentdEndpoint(host: '127.0.0.1', port: 1),
        ),
      ],
    );
    addTearDown(real.dispose);
    final sub = real.listen(agentdClientProvider('p1'), (_, _) {});
    await settle();
    final client = (await real.read(agentdClientProvider('p1').future))!;
    sub.close();
    await settle();
    await expectLater(
      client.send('x').timeout(const Duration(seconds: 5)),
      throwsA(
        isA<AgentdCommandException>().having(
          (e) => e.kind,
          'kind',
          AgentdCommandError.closed,
        ),
      ),
    );
  });

  group('SftpFileService shares its single SFTP session', () {
    test('sharedSession is the session listings use (one open)', () async {
      var opens = 0;
      final fake = FakeSftpSession(home: '/h');
      final service = SftpFileService.withOpener(() async {
        opens++;
        return fake;
      });
      addTearDown(service.close);
      final a = await service.sharedSession();
      await service.list('/');
      final b = await service.sharedSession();
      expect(identical(a, fake), isTrue);
      expect(identical(a, b), isTrue);
      expect(opens, 1);
    });
  });
}
