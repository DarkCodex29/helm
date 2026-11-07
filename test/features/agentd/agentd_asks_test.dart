@Timeout(Duration(seconds: 30))
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/agentd/data/agentd_asks.dart';
import 'package:helm/features/agentd/data/agentd_client.dart';
import 'package:helm/features/agentd/data/agentd_providers.dart';
import 'package:helm/features/agentd/domain/agentd_endpoint.dart';
import 'package:helm_protocol/helm_protocol.dart' as proto;

import 'support/fakes.dart';

const _token = 'FAKEfakeFAKEfakeFAKEfakeFAKEfakeFAKEfakeFAK';

proto.AskMessage _ask(String id, {String title = 'Proceed?'}) =>
    proto.AskMessage(requestId: id, method: 'confirm', title: title);

void main() {
  late FakeConnector connector;
  late List<AgentdClient> built;
  late ProviderContainer c;

  ProviderContainer container({bool nullClient = false}) {
    final k = ProviderContainer(
      overrides: [
        agentdClientProvider.overrideWith((ref, id) async {
          if (nullClient) return null;
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
    addTearDown(k.dispose);
    return k;
  }

  setUp(() {
    connector = FakeConnector();
    built = [];
    c = container();
  });

  List<String> ids(ProviderContainer k) => [
    for (final a in k.read(agentdAsksProvider('p1')).valueOrNull ?? const [])
      a.requestId,
  ];

  test('an ask is added, then removed when it is resolved', () async {
    c.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    connector.last.serveReady();
    connector.last.serve(_ask('a1'));
    await pump();
    expect(ids(c), ['a1']);
    connector.last.serve(_ask('a2'));
    await pump();
    expect(ids(c), ['a1', 'a2']);
    connector.last.serve(const proto.AskResolvedMessage('a1'));
    await pump();
    expect(ids(c), ['a2']);
  });

  test('a replay after ready clears first: no duplicates, no ghosts', () async {
    c.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    connector.last.serveReady();
    connector.last.serve(_ask('a1'));
    connector.last.serve(_ask('a2'));
    await pump();
    expect(ids(c), ['a1', 'a2']);
    // The daemon replays only what is still open, right after ready.
    connector.last.serveReady();
    connector.last.serve(_ask('a2'));
    await pump();
    expect(ids(c), ['a2']);
  });

  test('the same ask twice is replaced, not duplicated', () async {
    c.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    connector.last.serveReady();
    connector.last.serve(_ask('a1', title: 'old'));
    connector.last.serve(_ask('a1', title: 'new'));
    await pump();
    final list = c.read(agentdAsksProvider('p1')).requireValue;
    expect(list.map((a) => a.title), ['new']);
  });

  test('frames that are not asks are ignored', () async {
    c.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    connector.last.serveReady();
    connector.last.serve(_ask('a1'));
    connector.last.serve(
      const proto.MessageDeltaMessage(messageId: 'm', delta: 'x'),
    );
    connector.last.serve(const proto.AskResolvedMessage('unknown'));
    await pump();
    expect(ids(c), ['a1']);
  });

  test('the emitted list is immutable', () async {
    c.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    connector.last.serveReady();
    connector.last.serve(_ask('a1'));
    await pump();
    final list = c.read(agentdAsksProvider('p1')).requireValue;
    expect(() => list.add(_ask('x')), throwsUnsupportedError);
  });

  test('with the states provider: one client and one socket', () async {
    c.listen(agentdClientStatesProvider('p1'), (_, _) {});
    c.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    expect(built, hasLength(1));
    expect(connector.channels, hasLength(1));
  });

  test('alone, the asks provider still opens exactly one socket', () async {
    c.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    expect(built, hasLength(1));
    expect(connector.channels, hasLength(1));
  });

  test('no client yields an empty list', () async {
    final k = container(nullClient: true);
    k.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    expect(k.read(agentdAsksProvider('p1')).requireValue, isEmpty);
  });

  test('disposing the provider closes the client', () async {
    final sub = c.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    sub.close();
    await pump(20);
    expect(connector.channels.single.closedByClient, isTrue);
  });

  test('a provider subscribed AFTER the ask arrived still lists it', () async {
    c.listen(agentdClientStatesProvider('p1'), (_, _) {});
    await pump(20);
    connector.last.serveReady();
    connector.last.serve(_ask('a1'));
    await pump();
    // Nobody was watching the asks yet (inactive tab).
    c.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    expect(ids(c), ['a1']);
    expect(built, hasLength(1));
  });

  test('switching away and back (dispose, re-create) keeps the ask', () async {
    c.listen(agentdClientStatesProvider('p1'), (_, _) {});
    final first = c.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    connector.last.serveReady();
    connector.last.serve(_ask('a1'));
    await pump();
    expect(ids(c), ['a1']);
    first.close(); // the tab is no longer active
    await pump(20);
    connector.last.serve(_ask('a2')); // arrives while away
    await pump();
    c.listen(agentdAsksProvider('p1'), (_, _) {}); // back
    await pump(20);
    expect(ids(c), ['a1', 'a2']);
    expect(built, hasLength(1));
    expect(connector.channels, hasLength(1));
  });

  test('a rebuilt client resets the list to ITS snapshot', () async {
    final k = ProviderContainer(
      overrides: [
        agentdClientProvider.overrideWith((ref, id) async {
          ref.watch(agentdTokenVersionProvider(id));
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
    addTearDown(k.dispose);
    k.listen(agentdClientStatesProvider('p1'), (_, _) {});
    k.listen(agentdAsksProvider('p1'), (_, _) {});
    await pump(20);
    connector.last.serveReady();
    connector.last.serve(_ask('old'));
    await pump();
    expect(ids(k), ['old']);

    // A token (or host) change rebuilds the client.
    k.read(agentdTokenVersionProvider('p1').notifier).state++;
    await pump(30);
    expect(built, hasLength(2));
    expect(built.first.openAsks, isEmpty); // closed
    expect(ids(k), isEmpty, reason: 'old client asks must not leak');
    connector.last.serveReady();
    connector.last.serve(_ask('new'));
    await pump();
    expect(ids(k), ['new']);
  });
}
