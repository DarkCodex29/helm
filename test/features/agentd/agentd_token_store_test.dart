@Timeout(Duration(seconds: 30))
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/agentd/data/agentd_token_store.dart';

import '../../helpers/fake_secure_storage.dart';
import '../../helpers/fake_sftp_session.dart';

/// A fake token that has the real shape (43 base64url chars) but is not one.
const _token = 'FAKEfakeFAKEfakeFAKEfakeFAKEfakeFAKEfakeFAK';

/// Records the Keychain options of every call.
class _RecordingStorage extends FakeSecureStorage {
  final writeOptions = <AppleOptions?>[];
  final readOptions = <AppleOptions?>[];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    writeOptions.add(iOptions);
    return super.write(key: key, value: value, iOptions: iOptions);
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    readOptions.add(iOptions);
    return super.read(key: key, iOptions: iOptions);
  }
}

FakeSftpSession _sftpWith(List<int> bytes, {Object? openError}) =>
    FakeSftpSession(
      home: '/home/someone',
      files: {'/home/someone/.helm-agentd/token': FakeRemoteFile(bytes)},
      openError: openError,
    );

void main() {
  late _RecordingStorage storage;
  late AgentdTokenStore store;
  setUp(() {
    storage = _RecordingStorage();
    store = AgentdTokenStore(storage: storage);
  });

  group('storage', () {
    test('writes with first_unlock_this_device and reads back', () async {
      await store.write('p1', _token);

      expect(await store.read('p1'), _token);
      expect(storage.writeOptions, hasLength(1));
      final options = storage.writeOptions.single! as IOSOptions;
      expect(
        options.params['accessibility'],
        KeychainAccessibility.first_unlock_this_device.name,
      );
      expect(
        (storage.readOptions.single! as IOSOptions).params['accessibility'],
        KeychainAccessibility.first_unlock_this_device.name,
      );
    });

    test('is keyed per profile', () async {
      await store.write('p1', _token);
      expect(await store.read('p2'), isNull);
      expect(
        AgentdTokenStore.storageKey('p1'),
        isNot(AgentdTokenStore.storageKey('p2')),
      );
    });

    test('refuses to store a malformed token, without echoing it', () async {
      await expectLater(
        store.write('p1', 'not-a-token-secret'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('not-a-token-secret')),
          ),
        ),
      );
      expect(storage.values, isEmpty);
    });

    test('delete removes it', () async {
      await store.write('p1', _token);
      await store.delete('p1');
      expect(await store.read('p1'), isNull);
    });
  });

  group('storage failures', () {
    Future<Object> thrownBy(Future<Object?> Function() f) async {
      try {
        await f();
      } catch (e) {
        return e;
      }
      fail('did not throw');
    }

    test(
      'every public method throws a fixed typed exception, no text',
      () async {
        final s = AgentdTokenStore(storage: _ThrowingAll());
        for (final f in <Future<Object?> Function()>[
          () => s.write('p1', _token),
          () => s.read('p1'),
          () => s.delete('p1'),
        ]) {
          final e = await thrownBy(f);
          expect(e, isA<AgentdTokenStoreException>());
          expect(e.toString(), isNot(contains(_token)));
          expect(e.toString(), isNot(contains('FAKEfake')));
          expect(e.toString(), isNot(contains('p1')));
          expect(e.toString(), isNot(contains('StateError')));
        }
      },
    );

    test('the exception has no chained cause', () async {
      final s = AgentdTokenStore(storage: _ThrowingAll());
      final e = await thrownBy(() => s.write('p1', _token));
      expect(e, isA<AgentdTokenStoreException>());
      // Only a kind: nothing that could hold the original error.
      expect(
        e.toString(),
        'AgentdTokenStoreException(${(e as AgentdTokenStoreException).kind.name})',
      );
    });
  });

  group('provisionFromHost', () {
    test('stores a valid token, trimmed, from the home directory', () async {
      final sftp = _sftpWith(utf8.encode('$_token\n'));

      final outcome = await store.provisionFromHost(sftp, 'p1');

      expect(outcome, isA<TokenStored>());
      expect(await store.read('p1'), _token);
      expect(sftp.openedPaths, ['/home/someone/.helm-agentd/token']);
      expect(sftp.openedHandles.single.closed, isTrue);
    });

    test('notFound when the file does not exist', () async {
      final sftp = FakeSftpSession(home: '/home/someone');

      final outcome = await store.provisionFromHost(sftp, 'p1');

      expect(outcome, isA<TokenNotFound>());
      expect(storage.values, isEmpty);
    });

    for (final bad in <String, List<int>>{
      'too short': utf8.encode('abc'),
      'empty': const [],
      'bad alphabet': utf8.encode('${_token.substring(0, 42)}!'),
      'padded base64': utf8.encode('$_token='),
      'not utf8': const [0xff, 0xfe, 0xfd],
      'huge file': List.filled(100000, 0x41),
    }.entries) {
      test('invalid: ${bad.key}', () async {
        final outcome = await store.provisionFromHost(
          _sftpWith(bad.value),
          'p1',
        );

        expect(outcome, isA<TokenInvalid>());
        expect(storage.values, isEmpty);
      });
    }

    test(
      'failed on a transport error, closing the handle path safely',
      () async {
        final sftp = _sftpWith(
          utf8.encode(_token),
          openError: StateError('boom $_token'),
        );

        final outcome = await store.provisionFromHost(sftp, 'p1');

        expect(outcome, isA<TokenProvisionFailed>());
        expect(storage.values, isEmpty);
      },
    );

    test('failed when the home directory cannot be resolved', () async {
      final sftp = FakeSftpSession(absoluteError: StateError('no home'));
      expect(
        await store.provisionFromHost(sftp, 'p1'),
        isA<TokenProvisionFailed>(),
      );
    });

    test('failed when storing throws', () async {
      final failing = AgentdTokenStore(storage: _ThrowingStorage());
      expect(
        await failing.provisionFromHost(_sftpWith(utf8.encode(_token)), 'p1'),
        isA<TokenProvisionFailed>(),
      );
    });

    test('the token never appears in any outcome or exception text', () async {
      final outcomes = [
        await store.provisionFromHost(_sftpWith(utf8.encode(_token)), 'p1'),
        await store.provisionFromHost(FakeSftpSession(), 'p1'),
        await store.provisionFromHost(_sftpWith(utf8.encode('x$_token')), 'p2'),
        await store.provisionFromHost(
          _sftpWith(utf8.encode(_token), openError: StateError('leak $_token')),
          'p3',
        ),
        await AgentdTokenStore(
          storage: _ThrowingStorage(),
        ).provisionFromHost(_sftpWith(utf8.encode(_token)), 'p4'),
      ];

      for (final o in outcomes) {
        expect(o.toString(), isNot(contains(_token)));
        expect(o.toString(), isNot(contains('FAKEfake')));
      }
      expect(outcomes.first.toString(), 'TokenStored()');
    });
  });
}

class _ThrowingAll extends FakeSecureStorage {
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => throw StateError('write failed key=$key value=$value');

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => throw StateError('read failed $_token');

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => throw StateError('delete failed $_token');
}

class _ThrowingStorage extends FakeSecureStorage {
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => throw StateError('keychain locked, value=$value');
}
