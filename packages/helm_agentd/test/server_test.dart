@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:helm_agentd/helm_agentd.dart';
import 'package:helm_protocol/helm_protocol.dart';
import 'package:test/test.dart';

import 'support/stub_bridge.dart';
import 'support/ws_client.dart';

Future<void> chmod(String mode, String path) async {
  final r = await Process.run('chmod', [mode, path]).timeout(bound);
  expect(r.exitCode, 0);
}

void main() {
  late Directory tmp;
  late String tokenPath;
  late TokenStore tokens;
  late StubBridge bridge;
  final servers = <AgentServer>[];
  final clients = <TestClient>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('helm_agentd_server_');
    // systemTemp dirs are 0700 on macOS but not everywhere; the token store
    // now refuses a token whose directory chain is open to others.
    await chmod('700', tmp.path);
    tokenPath = '${tmp.path}/state/token';
    tokens = TokenStore(tokenPath);
    await tokens.ensure();
    bridge = StubBridge();
  });

  tearDown(() async {
    for (final c in clients) {
      await c.dispose();
    }
    clients.clear();
    for (final s in servers) {
      await s.close().timeout(bound);
    }
    servers.clear();
    await tmp.delete(recursive: true);
  });

  Future<AgentServer> startServer({
    Duration helloTimeout = const Duration(seconds: 5),
    Set<String> allowedOrigins = const {},
  }) async {
    final s = AgentServer(
      bridge: bridge,
      tokens: tokens,
      port: 0,
      helloTimeout: helloTimeout,
      allowedOrigins: allowedOrigins,
    );
    servers.add(s);
    await s.start().timeout(bound);
    return s;
  }

  Future<TestClient> connect(
    AgentServer s, {
    Map<String, Object>? headers,
  }) async {
    final c = await TestClient.connect(s.port, headers: headers);
    clients.add(c);
    return c;
  }

  Future<String> currentToken() => File(tokenPath).readAsString();

  group('token store', () {
    test(
      'creates a 43-char base64url token, 0600 file in a 0700 dir',
      () async {
        final token = (await currentToken()).trim();
        expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        // 32 bytes decode back.
        expect(base64Url.decode(base64Url.normalize(token)), hasLength(32));
        expect(File(tokenPath).statSync().mode & 0x1FF, 0x180); // 0600
        expect(Directory('${tmp.path}/state').statSync().mode & 0x1FF, 0x1C0);
      },
    );

    test('ensure keeps an existing secure token', () async {
      final before = await currentToken();
      await TokenStore(tokenPath).ensure();
      expect(await currentToken(), before);
    });

    test(
      'refuses a group/world-readable token file, without leaking it',
      () async {
        final secret = (await currentToken()).trim();
        await chmod('644', tokenPath);
        final fresh = TokenStore(tokenPath);
        await expectLater(
          fresh.ensure(),
          throwsA(
            isA<TokenFileException>().having(
              (e) => e.toString(),
              'message',
              allOf(contains(tokenPath), isNot(contains(secret))),
            ),
          ),
        );
        final server = AgentServer(bridge: bridge, tokens: fresh, port: 0);
        await expectLater(server.start(), throwsA(isA<TokenFileException>()));
        await server.close();
      },
    );

    test('refuses a group-readable file (0640)', () async {
      await chmod('640', tokenPath);
      await expectLater(
        TokenStore(tokenPath).ensure(),
        throwsA(isA<TokenFileException>()),
      );
    });

    test('verify is false once the file turned insecure', () async {
      final secret = (await currentToken()).trim();
      expect(tokens.verify(secret), isTrue);
      await chmod('644', tokenPath);
      expect(tokens.verify(secret), isFalse);
    });

    test('verify rejects wrong, empty and prefix tokens', () async {
      final secret = (await currentToken()).trim();
      expect(tokens.verify(secret), isTrue);
      expect(tokens.verify(''), isFalse);
      expect(tokens.verify(secret.substring(1)), isFalse);
      expect(tokens.verify('${secret}x'), isFalse);
    });

    test('constantTimeEquals', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
    });

    test('default path lives under ~/.helm-agentd', () {
      expect(TokenStore.defaultPath(), endsWith('/.helm-agentd/token'));
    });

    test(
      'refuses a token path that is a symlink, even to a 0600 file',
      () async {
        final link = '${tmp.path}/state/link-token';
        Link(link).createSync(tokenPath);
        await expectLater(
          TokenStore(link).ensure(),
          throwsA(isA<TokenFileException>()),
        );
        expect(TokenStore(link).verify((await currentToken()).trim()), isFalse);
      },
    );

    test(
      'refuses to create the token in a directory others can enter',
      () async {
        final loose = Directory('${tmp.path}/loose')..createSync();
        await chmod('755', loose.path);
        final path = '${loose.path}/token';
        await expectLater(
          TokenStore(path).ensure(),
          throwsA(isA<TokenFileException>()),
        );
        expect(File(path).existsSync(), isFalse, reason: 'no secret written');
      },
    );

    test('refuses an existing token in a directory others can enter', () async {
      await chmod('755', '${tmp.path}/state');
      final secret = (await currentToken()).trim();
      await expectLater(
        TokenStore(tokenPath).ensure(),
        throwsA(isA<TokenFileException>()),
      );
      expect(tokens.verify(secret), isFalse);
    });
  });

  group('listener', () {
    test('binds to loopback by default', () async {
      final s = AgentServer(bridge: bridge, tokens: tokens, port: 0);
      servers.add(s);
      await s.start().timeout(bound);
      expect(s.address.isLoopback, isTrue);
      expect(s.address.address, '127.0.0.1');
    });

    test('a plain HTTP request is not served', () async {
      final s = await startServer();
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final req = await http.get('127.0.0.1', s.port, '/').timeout(bound);
      final res = await req.close().timeout(bound);
      await res.drain<void>().timeout(bound);
      expect(res.statusCode, 426);
    });

    test('close releases the port and the sockets', () async {
      final s = await startServer();
      final c = await connect(s);
      await c.hello((await currentToken()).trim());
      await c.next();
      final port = s.port;
      await s.close().timeout(bound);
      await c.closeCode();
      await expectLater(
        Socket.connect('127.0.0.1', port).timeout(bound),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('authentication', () {
    test('no hello within the timeout closes 4401, nothing was sent', () async {
      final s = await startServer(
        helloTimeout: const Duration(milliseconds: 150),
      );
      final c = await connect(s);
      expect(await c.closeCode(), 4401);
      expect(c.frames, isEmpty);
      expect(bridge.attached, isEmpty);
    });

    test('wrong token closes 4401 and sends nothing', () async {
      final s = await startServer();
      final c = await connect(s);
      await c.hello('not-the-token');
      expect(await c.closeCode(), 4401);
      expect(c.frames, isEmpty);
      expect(bridge.attached, isEmpty);
    });

    test('wrong protocol closes 4400', () async {
      final s = await startServer();
      final c = await connect(s);
      await c.hello((await currentToken()).trim(), protocol: 99);
      expect(await c.closeCode(), 4400);
      expect(c.frames, isEmpty);
    });

    test('wrong token AND wrong protocol reports 4401 (no oracle)', () async {
      final s = await startServer();
      final c = await connect(s);
      await c.hello('nope', protocol: 99);
      expect(await c.closeCode(), 4401);
    });

    test('a first frame that is not hello closes 4401', () async {
      final s = await startServer();
      final c = await connect(s);
      c.sendMessage(const ClientSend(text: 'hi', requestId: 'r1'));
      expect(await c.closeCode(), 4401);
      expect(bridge.received, isEmpty);
    });

    test('garbage and malformed hello close 4401', () async {
      final s = await startServer();
      final a = await connect(s);
      a.socket.add('not json');
      expect(await a.closeCode(), 4401);
      final b = await connect(s);
      b.sendJson({'type': 'hello', 'token': 5, 'protocol': 'x'});
      expect(await b.closeCode(), 4401);
    });

    test('good hello: ready is seq 1, later frames count up', () async {
      final s = await startServer();
      final c = await connect(s);
      await c.hello((await currentToken()).trim());
      final ready = await c.next();
      expect(ready.seq, 1);
      expect(ready.message, isA<ReadyMessage>());
      c.sendMessage(const ClientGetState());
      c.sendMessage(const ClientGetState());
      expect((await c.next()).seq, 2);
      expect((await c.next()).seq, 3);
      expect(bridge.received, hasLength(2));
    });

    test('seq is per connection', () async {
      final s = await startServer();
      final token = (await currentToken()).trim();
      final a = await connect(s);
      await a.hello(token);
      await a.next();
      a.sendMessage(const ClientGetState());
      await a.next();
      final b = await connect(s);
      await b.hello(token);
      expect((await b.next()).seq, 1);
    });

    test('a token rotated on disk is honoured without a restart', () async {
      final s = await startServer();
      final old = (await currentToken()).trim();
      final first = await connect(s);
      await first.hello(old);
      expect((await first.next()).message, isA<ReadyMessage>());

      const fresh = 'rotated-token-value-0123456789abcdefghijklm';
      await File(tokenPath).writeAsString('$fresh\n');
      await chmod('600', tokenPath);

      final stale = await connect(s);
      await stale.hello(old);
      expect(await stale.closeCode(), 4401);

      final ok = await connect(s);
      await ok.hello(fresh);
      expect((await ok.next()).message, isA<ReadyMessage>());
    });

    test(
      'a second hello after authentication is an error, not forwarded',
      () async {
        final s = await startServer();
        final token = (await currentToken()).trim();
        final c = await connect(s);
        await c.hello(token);
        await c.next();
        await c.hello(token);
        final f = await c.next();
        expect(f.message, isA<ErrorMessage>());
        expect((f.message as ErrorMessage).code, 'already_authenticated');
        expect(bridge.received, isEmpty);
      },
    );

    test('the bridge sees detach when the client leaves', () async {
      final s = await startServer();
      final c = await connect(s);
      await c.hello((await currentToken()).trim());
      await c.next();
      await c.socket.close();
      await c.closeCode();
      final end = DateTime.now().add(bound);
      while (bridge.detached.isEmpty && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(bridge.detached, hasLength(1));
    });

    test('an unauthenticated socket never reaches the bridge', () async {
      final s = await startServer(
        helloTimeout: const Duration(milliseconds: 150),
      );
      final c = await connect(s);
      c.sendMessage(const ClientAbort());
      expect(await c.closeCode(), 4401);
      expect(bridge.attached, isEmpty);
      expect(bridge.received, isEmpty);
    });
  });

  group('origin', () {
    test(
      'an Origin header outside the allowlist is rejected with 403',
      () async {
        final s = await startServer();
        await expectLater(
          TestClient.connect(
            s.port,
            headers: {'Origin': 'https://evil.example'},
          ),
          throwsA(
            isA<WebSocketException>().having(
              (e) => e.toString(),
              'text',
              contains('403'),
            ),
          ),
        );
      },
    );

    test('an allowlisted Origin is accepted', () async {
      final s = await startServer(allowedOrigins: {'https://app.example'});
      final c = await connect(s, headers: {'Origin': 'https://app.example'});
      await c.hello((await currentToken()).trim());
      expect((await c.next()).message, isA<ReadyMessage>());
    });

    test('no Origin header (native clients) is accepted', () async {
      final s = await startServer();
      final c = await connect(s);
      await c.hello((await currentToken()).trim());
      expect((await c.next()).message, isA<ReadyMessage>());
    });
  });

  group('frame limits', () {
    final big = 'x' * (1024 * 1024 + 1);

    test('an oversized frame before auth closes 1009', () async {
      final s = await startServer();
      final c = await connect(s);
      c.socket.add(big);
      expect(await c.closeCode(), 1009);
    });

    test('an oversized frame after auth closes 1009', () async {
      final s = await startServer();
      final c = await connect(s);
      await c.hello((await currentToken()).trim());
      await c.next();
      c.socket.add(big);
      expect(await c.closeCode(), 1009);
      expect(bridge.received, isEmpty);
    });

    test('a multi-byte frame over 1 MiB in bytes closes 1009', () async {
      final s = await startServer();
      final c = await connect(s);
      // 400k three-byte chars: under 1 MiB in characters, over in bytes.
      c.socket.add('€' * 400000);
      expect(await c.closeCode(), 1009);
    });

    test('a binary frame closes 1003', () async {
      final s = await startServer();
      final c = await connect(s);
      c.socket.add([1, 2, 3]);
      expect(await c.closeCode(), 1003);
    });

    test('a binary frame after auth closes 1003', () async {
      final s = await startServer();
      final c = await connect(s);
      await c.hello((await currentToken()).trim());
      await c.next();
      c.socket.add([1, 2, 3]);
      expect(await c.closeCode(), 1003);
    });
  });
}
