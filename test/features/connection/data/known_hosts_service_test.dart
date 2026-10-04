import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';

import '../../../helpers/fake_secure_storage.dart';

/// A [FlutterSecureStorage] stand-in whose [readAll] always fails.
///
/// Pins the distinction `listPinnedHosts` is required to keep: a store
/// that could not be read is not evidence it holds nothing, so this proves
/// the method propagates the failure rather than returning an empty list.
class _FailingSecureStorage extends FlutterSecureStorage {
  const _FailingSecureStorage();

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    throw StateError('keychain unavailable');
  }
}

/// Real `ssh-keygen -lf` output, not a fabricated string.
///
/// Produced by generating a throwaway key pair and reading back what
/// OpenSSH itself prints:
///
/// ```
/// $ ssh-keygen -t ed25519 -N '' -C helm-test -f hk_ed -q
/// $ ssh-keygen -lf hk_ed.pub
/// 256 SHA256:uXVKYUuorbYlvO5eHey0nV9ncWa+6hojcBKZZ80PlzI helm-test (ED25519)
/// ```
///
/// Independently confirmed to be exactly what dartssh2 3.3.1 computes:
/// `SHA256Digest().process(hostkey)` base64-encoded with padding stripped
/// (`ssh_transport.dart:47`) reproduces this byte for byte from the same
/// public key blob. That equality is the entire point of this change — it
/// is what makes the value helm shows comparable to the server.
///
/// The 43-character tail is not arbitrary: a SHA-256 digest is 32 bytes,
/// which base64-encodes to 44 characters including one `=` of padding, and
/// OpenSSH strips the padding.
const _ed25519Fingerprint =
    'SHA256:uXVKYUuorbYlvO5eHey0nV9ncWa+6hojcBKZZ80PlzI';

/// A second real `ssh-keygen -lf` fingerprint, from an RSA key on the same
/// throwaway run. Used wherever a test needs a DIFFERENT valid fingerprint
/// of the same shape.
const _rsaFingerprint = 'SHA256:r8vvDRdBfIXWS7qkknHp7dTA1bYYd6aBBNmtNeI8Bag';

/// A third real `ssh-keygen -lf` fingerprint, from an ECDSA key:
///
/// ```
/// $ ssh-keygen -t ecdsa -b 256 -N '' -C helm-test -f hk_ec -q
/// $ ssh-keygen -lf hk_ec.pub
/// 256 SHA256:H7809R87hCkC2U+ltM91UhQ69yoUCMYXkg5ovLZlK7c helm-test (ECDSA)
/// ```
///
/// ECDSA specifically, because it is the algorithm in the downgrade this
/// change closes: an attacker who controls negotiation advertises only
/// `ecdsa-sha2-nistp256` against a host helm knows by `ssh-ed25519`.
const _ecdsaFingerprint = 'SHA256:H7809R87hCkC2U+ltM91UhQ69yoUCMYXkg5ovLZlK7c';

const _ed25519Type = 'ssh-ed25519';
const _rsaType = 'ssh-rsa';
const _ecdsaType = 'ecdsa-sha2-nistp256';

/// Builds what dartssh2 hands `onVerifyHostKey`: the UTF-8 bytes of the
/// OpenSSH fingerprint string.
Uint8List _bytesOf(String fingerprint) =>
    Uint8List.fromList(utf8.encode(fingerprint));

String _v1Key(String host, int port) =>
    '${AppConstants.knownHostStorageKeyPrefix}$host:$port';

String _v2Key(String host, int port, String keyType) =>
    '${AppConstants.knownHostV2StorageKeyPrefix}$host:$port:$keyType';

void main() {
  late FakeSecureStorage storage;
  late KnownHostsService service;

  setUp(() {
    storage = FakeSecureStorage();
    service = KnownHostsService(storage: storage);
  });

  group('decodeFingerprint', () {
    test('returns the dartssh2 string verbatim, with no re-hashing', () {
      expect(
        KnownHostsService.decodeFingerprint(_bytesOf(_ed25519Fingerprint)),
        _ed25519Fingerprint,
      );
    });

    test('matches what ssh-keygen -lf prints for the same key', () {
      // The regression this whole change exists to prevent. Helm used to
      // SHA-256 the bytes it was handed, producing a value that shared the
      // `SHA256:` shape and could never equal this one.
      final decoded = KnownHostsService.decodeFingerprint(
        _bytesOf(_ed25519Fingerprint),
      );

      expect(decoded, 'SHA256:uXVKYUuorbYlvO5eHey0nV9ncWa+6hojcBKZZ80PlzI');
    });

    test('does not prepend a second SHA256: prefix', () {
      // ConnectBot shipped `SHA256:SHA256:...` by re-adding a prefix the
      // library string already carries. The tail already contains no
      // colon, so counting them is a sufficient and exact check.
      final decoded = KnownHostsService.decodeFingerprint(
        _bytesOf(_ed25519Fingerprint),
      );

      expect(decoded.split(':').length, 2);
      expect(decoded, isNot(contains('SHA256:SHA256:')));
    });

    test('preserves the standard base64 alphabet', () {
      // dartssh2 uses `base64.encode`, not base64url, so `+` and `/` are
      // legal in the tail. A decoder that normalised them would silently
      // change the fingerprint of roughly one key in three.
      expect(_ed25519Fingerprint, contains('+'));
      expect(
        KnownHostsService.decodeFingerprint(_bytesOf(_ed25519Fingerprint)),
        contains('+'),
      );
    });

    group('fails closed', () {
      test('on an empty input', () {
        expect(
          () => KnownHostsService.decodeFingerprint(Uint8List(0)),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });

      test('on a value with no SHA256: prefix', () {
        expect(
          () => KnownHostsService.decodeFingerprint(
            _bytesOf('uXVKYUuorbYlvO5eHey0nV9ncWa+6hojcBKZZ80PlzI'),
          ),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });

      test('on an MD5-style fingerprint', () {
        // What dartssh2 2.16.0 handed this callback. A future downgrade,
        // or a library that changes its mind again, must not be pinned.
        expect(
          () => KnownHostsService.decodeFingerprint(
            _bytesOf('MD5:ac:5f:1e:9b:33:2c:44:0a:11:8e:76:2d:90:c3:41:5b'),
          ),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });

      test('on raw digest bytes rather than an encoded string', () {
        // 2.16.0 handed over the digest itself, not a string. Most such
        // buffers are not even valid UTF-8, and none carry the prefix.
        expect(
          () => KnownHostsService.decodeFingerprint(
            Uint8List.fromList(List<int>.generate(16, (i) => i * 16)),
          ),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });

      test('on invalid UTF-8', () {
        expect(
          () => KnownHostsService.decodeFingerprint(
            Uint8List.fromList([0xC3, 0x28, 0xA0, 0xFF]),
          ),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });

      test('on a lowercase prefix', () {
        expect(
          () => KnownHostsService.decodeFingerprint(
            _bytesOf('sha256:uXVKYUuorbYlvO5eHey0nV9ncWa+6hojcBKZZ80PlzI'),
          ),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });

      test('on an already-doubled prefix', () {
        expect(
          () => KnownHostsService.decodeFingerprint(
            _bytesOf('SHA256:$_ed25519Fingerprint'),
          ),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });

      test('on a tail that is too short for a SHA-256 digest', () {
        expect(
          () => KnownHostsService.decodeFingerprint(_bytesOf('SHA256:abc')),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });

      test('on a tail that is too long for a SHA-256 digest', () {
        expect(
          () => KnownHostsService.decodeFingerprint(
            _bytesOf('${_ed25519Fingerprint}extra'),
          ),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });

      test('on a padded tail', () {
        // OpenSSH strips padding. A padded value is not what any side of
        // this comparison produces, so it is not silently normalised.
        expect(
          () => KnownHostsService.decodeFingerprint(
            _bytesOf('SHA256:uXVKYUuorbYlvO5eHey0nV9ncWa+6hojcBKZZ80Plz='),
          ),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });

      test('on base64url characters', () {
        expect(
          () => KnownHostsService.decodeFingerprint(
            _bytesOf('SHA256:uXVKYUuorbYlvO5eHey0nV9ncWa-6hojcBKZZ80PlzI'),
          ),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });

      test('on whitespace around an otherwise valid value', () {
        expect(
          () => KnownHostsService.decodeFingerprint(
            _bytesOf(' $_ed25519Fingerprint'),
          ),
          throwsA(isA<HostKeyFingerprintFormatException>()),
        );
      });
    });
  });

  group('verifyHostKey', () {
    test('returns firstSeen and pins the key on first contact', () async {
      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_ed25519Fingerprint),
      );

      expect(result.verdict, HostKeyVerdict.firstSeen);
      expect(result.isTrusted, isTrue);
      expect(result.storedFingerprint, isNull);
      expect(result.receivedFingerprint, _ed25519Fingerprint);
      expect(result.keyType, _ed25519Type);
    });

    test('pins under a versioned, key-type-scoped storage key', () async {
      await service.verifyHostKey(
        host: 'example.com',
        port: 2222,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_ed25519Fingerprint),
      );

      expect(
        storage.values[_v2Key('example.com', 2222, _ed25519Type)],
        _ed25519Fingerprint,
      );
    });

    test('returns match when the same key is presented again', () async {
      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_ed25519Fingerprint),
      );

      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_ed25519Fingerprint),
      );

      expect(result.verdict, HostKeyVerdict.match);
      expect(result.isTrusted, isTrue);
      expect(result.storedFingerprint, _ed25519Fingerprint);
    });

    test('returns mismatch when a different key is presented', () async {
      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_ed25519Fingerprint),
      );

      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_rsaFingerprint),
      );

      expect(result.verdict, HostKeyVerdict.mismatch);
      expect(result.isTrusted, isFalse);
      expect(result.storedFingerprint, _ed25519Fingerprint);
      expect(result.receivedFingerprint, _rsaFingerprint);
    });

    test('does not overwrite a pinned key on mismatch', () async {
      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_ed25519Fingerprint),
      );

      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_rsaFingerprint),
      );

      expect(
        storage.values[_v2Key('example.com', 22, _ed25519Type)],
        _ed25519Fingerprint,
      );
    });

    test('fails closed when the library hands over an unreadable value', () {
      expect(
        () => service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf('not-a-fingerprint'),
        ),
        throwsA(isA<HostKeyFingerprintFormatException>()),
      );
    });

    test('pins nothing when the presented value cannot be read', () async {
      await expectLater(
        service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf('not-a-fingerprint'),
        ),
        throwsA(isA<HostKeyFingerprintFormatException>()),
      );

      expect(storage.values, isEmpty);
    });

    group('legacy pin migration', () {
      setUp(() async {
        // What helm 2.16.0-era builds wrote: SHA256(MD5(host key)) under
        // an unversioned, key-type-less storage key.
        storage.values[_v1Key('example.com', 22)] = _rsaFingerprint;
      });

      test('reports an unverifiable pin rather than a mismatch', () async {
        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        // The distinction this change turns on. Reusing `mismatch` would
        // raise the interception alarm for every already-pinned host on
        // the first launch after the upgrade, and teach the user that
        // helm's loudest warning is noise.
        expect(result.verdict, HostKeyVerdict.unverifiablePin);
        expect(result.verdict, isNot(HostKeyVerdict.mismatch));
      });

      test('does not let the connection continue', () async {
        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        // Helm cannot verify the old pin, so continuing would be an
        // unauthenticated trust decision made on the user's behalf.
        expect(result.isTrusted, isFalse);
      });

      test('carries what the surface needs to ask the user', () async {
        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        expect(result.host, 'example.com');
        expect(result.port, 22);
        expect(result.keyType, _ed25519Type);
        expect(result.receivedFingerprint, _ed25519Fingerprint);
        expect(result.storedFingerprint, _rsaFingerprint);
      });

      test('pins nothing until the user has accepted', () async {
        await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        expect(storage.values[_v2Key('example.com', 22, _ed25519Type)], isNull);
      });

      test('leaves the legacy entry in place until accepted', () async {
        await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        // A migration the user declined must still be a migration on the
        // next attempt, not a silent first contact.
        expect(storage.values[_v1Key('example.com', 22)], _rsaFingerprint);
      });

      test('is repeatable while the user keeps declining', () async {
        await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        final second = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        expect(second.verdict, HostKeyVerdict.unverifiablePin);
      });

      test('a current pin takes precedence over a stale legacy one', () async {
        storage.values[_v2Key('example.com', 22, _ed25519Type)] =
            _ed25519Fingerprint;

        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        // A legacy entry that outlived a crash between the write and the
        // delete must not re-raise a migration that already happened.
        expect(result.verdict, HostKeyVerdict.match);
      });

      test(
        'a real mismatch is still loud once the host has migrated',
        () async {
          storage.values[_v2Key('example.com', 22, _ed25519Type)] =
              _ed25519Fingerprint;

          final result = await service.verifyHostKey(
            host: 'example.com',
            port: 22,
            keyType: _ed25519Type,
            fingerprintBytes: _bytesOf(_rsaFingerprint),
          );

          expect(result.verdict, HostKeyVerdict.mismatch);
          expect(result.isTrusted, isFalse);
        },
      );

      test('another host is unaffected by this one being unmigrated', () async {
        final result = await service.verifyHostKey(
          host: 'other.example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        expect(result.verdict, HostKeyVerdict.firstSeen);
      });

      test('an unseen key type on a v1-only host still migrates', () async {
        // A superseded entry is not key-type-scoped, so helm cannot say
        // which algorithm it was written for. Calling this a NEW key type
        // would assert exactly the fact helm does not have, and the
        // resulting prompt would have to name the "already known" types —
        // of which there are none it can read. The migration gate is the
        // honest one: there is a prior trust decision here and helm cannot
        // compare it. Both verdicts gate the connection, so nothing is
        // silently pinned either way; only the copy differs.
        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ecdsaType,
          fingerprintBytes: _bytesOf(_ecdsaFingerprint),
        );

        expect(result.verdict, HostKeyVerdict.unverifiablePin);
        expect(result.isTrusted, isFalse);
        expect(result.knownKeyTypes, isEmpty);
      });

      test('a v2 pin of another type does not skip the migration', () async {
        // The interrupted-`acceptMigration` state: the v2 write landed and
        // the v1 delete did not. Both facts are true at once — there is an
        // unreadable pin AND a readable pin of another type — and the
        // unreadable one is reported, because it is the one the store
        // cannot reason about. Either way the connection is gated.
        storage.values[_v2Key('example.com', 22, _ed25519Type)] =
            _ed25519Fingerprint;

        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ecdsaType,
          fingerprintBytes: _bytesOf(_ecdsaFingerprint),
        );

        expect(result.verdict, HostKeyVerdict.unverifiablePin);
        expect(result.isTrusted, isFalse);
      });
    });

    group('multiple key types on one host', () {
      test('a new key type on a known host is gated, not pinned', () async {
        await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        // The downgrade this verdict exists to close. An attacker who
        // controls algorithm negotiation can advertise ONLY a type this
        // host has never presented, and every earlier build read the
        // absent entry as first contact and pinned the attacker's key
        // without a word. Adding the key type to the storage key is what
        // opened that path, so the fix belongs beside it.
        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _rsaType,
          fingerprintBytes: _bytesOf(_rsaFingerprint),
        );

        expect(result.verdict, HostKeyVerdict.unpinnedKeyType);
        expect(result.verdict, isNot(HostKeyVerdict.firstSeen));
        expect(result.verdict, isNot(HostKeyVerdict.mismatch));
        expect(result.isTrusted, isFalse);
      });

      test('pins nothing until the user has accepted', () async {
        await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _rsaType,
          fingerprintBytes: _bytesOf(_rsaFingerprint),
        );

        expect(storage.values[_v2Key('example.com', 22, _rsaType)], isNull);
      });

      test('names the key types already on record', () async {
        // The surface has to tell the user WHICH type this host was
        // known by, because that is the fact that makes the new one worth
        // a second look. A prompt that only shows the new type asks the
        // user to authorize something it has not explained.
        storage.values[_v2Key('example.com', 22, _ed25519Type)] =
            _ed25519Fingerprint;
        storage.values[_v2Key('example.com', 22, _ecdsaType)] =
            _ecdsaFingerprint;

        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _rsaType,
          fingerprintBytes: _bytesOf(_rsaFingerprint),
        );

        // Sorted, so the copy is stable rather than ordered by whatever
        // the keychain happened to enumerate.
        expect(result.knownKeyTypes, [_ecdsaType, _ed25519Type]);
        expect(result.knownKeyTypes, isNot(contains(_rsaType)));
      });

      test('carries what the surface needs to ask the user', () async {
        storage.values[_v2Key('example.com', 22, _ed25519Type)] =
            _ed25519Fingerprint;

        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _rsaType,
          fingerprintBytes: _bytesOf(_rsaFingerprint),
        );

        expect(result.host, 'example.com');
        expect(result.port, 22);
        expect(result.keyType, _rsaType);
        expect(result.receivedFingerprint, _rsaFingerprint);
        // No stored value: nothing was ever pinned for THIS key type, and
        // offering another type's fingerprint here would invite a
        // comparison between two keys that are supposed to differ.
        expect(result.storedFingerprint, isNull);
      });

      test('both pins coexist and each keeps matching', () async {
        await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );
        // Goes through the authorization path rather than a second
        // `verifyHostKey`, because a second key type no longer pins
        // itself — which is the whole point of the group above.
        await service.acceptNewKeyType(
          host: 'example.com',
          port: 22,
          keyType: _rsaType,
          fingerprint: _rsaFingerprint,
        );

        final ed = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );
        final rsa = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _rsaType,
          fingerprintBytes: _bytesOf(_rsaFingerprint),
        );

        expect(ed.verdict, HostKeyVerdict.match);
        expect(rsa.verdict, HostKeyVerdict.match);
      });

      test('a mismatch on one key type does not touch the other', () async {
        await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );
        await service.acceptNewKeyType(
          host: 'example.com',
          port: 22,
          keyType: _rsaType,
          fingerprint: _rsaFingerprint,
        );

        await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _rsaType,
          fingerprintBytes: _bytesOf(_ed25519Fingerprint),
        );

        expect(
          storage.values[_v2Key('example.com', 22, _ed25519Type)],
          _ed25519Fingerprint,
        );
        expect(
          storage.values[_v2Key('example.com', 22, _rsaType)],
          _rsaFingerprint,
        );
      });
    });

    group('genuine first contact stays silent', () {
      test('an unknown host is pinned without a prompt', () async {
        // The hole is a host helm ALREADY KNOWS presenting an unfamiliar
        // key type. A host with no entry of any type is ordinary Trust On
        // First Use, and turning that into a prompt would ask the user to
        // authorize a fingerprint they have nothing to weigh it against —
        // teaching them to tap through the very gate that protects the
        // known-host case.
        final result = await service.verifyHostKey(
          host: 'brand-new.example.com',
          port: 22,
          keyType: _ecdsaType,
          fingerprintBytes: _bytesOf(_ecdsaFingerprint),
        );

        expect(result.verdict, HostKeyVerdict.firstSeen);
        expect(result.isTrusted, isTrue);
        expect(result.knownKeyTypes, isEmpty);
        expect(
          storage.values[_v2Key('brand-new.example.com', 22, _ecdsaType)],
          _ecdsaFingerprint,
        );
      });

      test('another host being known does not gate this one', () async {
        storage.values[_v2Key('other.example.com', 22, _ed25519Type)] =
            _ed25519Fingerprint;

        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ecdsaType,
          fingerprintBytes: _bytesOf(_ecdsaFingerprint),
        );

        expect(result.verdict, HostKeyVerdict.firstSeen);
      });

      test('the same host on another port does not gate this one', () async {
        // Trust identity is host AND port. A pin for :22 says nothing
        // about the service answering on :2222, which may be an entirely
        // different machine behind a forward.
        storage.values[_v2Key('example.com', 22, _ed25519Type)] =
            _ed25519Fingerprint;

        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 2222,
          keyType: _ecdsaType,
          fingerprintBytes: _bytesOf(_ecdsaFingerprint),
        );

        expect(result.verdict, HostKeyVerdict.firstSeen);
      });
    });

    group('the known-host scan does not match a neighbouring host', () {
      // Detecting "this host is known by some other key type" means asking
      // the store a PREFIX question, and a prefix question over
      // `<host>:<port>:<keyType>` is one careless boundary away from
      // answering for the wrong machine. Each case here is a pair whose
      // storage keys share a leading run of characters; a scan that
      // stopped before the `:<port>:` terminator would answer yes for both
      // members of every pair.
      //
      // Both failure directions are wrong, but only one is dangerous:
      // over-matching turns a first contact into a prompt (noisy, safe),
      // while under-matching would put the silent pin back (quiet,
      // exploitable). These pin the boundary so neither drifts.

      test('a longer hostname sharing a prefix is a different host', () async {
        // `mac` is a prefix of `mac.local` as a plain string. It is not a
        // prefix of it as a trust identity.
        storage.values[_v2Key('mac.local', 22, _ed25519Type)] =
            _ed25519Fingerprint;

        final result = await service.verifyHostKey(
          host: 'mac',
          port: 22,
          keyType: _ecdsaType,
          fingerprintBytes: _bytesOf(_ecdsaFingerprint),
        );

        expect(result.verdict, HostKeyVerdict.firstSeen);
        expect(result.knownKeyTypes, isEmpty);
      });

      test('a shorter hostname sharing a prefix is a different host', () async {
        // The reverse direction of the pair above, because a scan can be
        // wrong in only one of them.
        storage.values[_v2Key('mac', 22, _ed25519Type)] = _ed25519Fingerprint;

        final result = await service.verifyHostKey(
          host: 'mac.local',
          port: 22,
          keyType: _ecdsaType,
          fingerprintBytes: _bytesOf(_ecdsaFingerprint),
        );

        expect(result.verdict, HostKeyVerdict.firstSeen);
        expect(result.knownKeyTypes, isEmpty);
      });

      test('an IP address is not a prefix of a longer one', () async {
        // `10.0.0.1` and `10.0.0.10` are the realistic form of this bug on
        // a LAN, where consecutive addresses are handed out in order and
        // both are genuinely reachable.
        storage.values[_v2Key('10.0.0.10', 22, _ed25519Type)] =
            _ed25519Fingerprint;

        final result = await service.verifyHostKey(
          host: '10.0.0.1',
          port: 22,
          keyType: _ecdsaType,
          fingerprintBytes: _bytesOf(_ecdsaFingerprint),
        );

        expect(result.verdict, HostKeyVerdict.firstSeen);
        expect(result.knownKeyTypes, isEmpty);
      });

      test('a port is not a prefix of a longer port', () async {
        // The same collision one segment along: `2` leads `22`. This is
        // what the trailing colon after the port defends.
        storage.values[_v2Key('example.com', 22, _ed25519Type)] =
            _ed25519Fingerprint;

        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 2,
          keyType: _ecdsaType,
          fingerprintBytes: _bytesOf(_ecdsaFingerprint),
        );

        expect(result.verdict, HostKeyVerdict.firstSeen);
        expect(result.knownKeyTypes, isEmpty);
      });

      test('a superseded entry is not read as a current pin', () async {
        // `helm_known_host_v2_` begins with `helm_known_host_`, so the two
        // prefixes overlap by construction. Scanning for the CURRENT
        // scheme must not sweep up entries written under the superseded
        // one — this host has only a v1 record, and reporting it as a
        // known key type would name a type helm cannot actually read.
        storage.values[_v1Key('example.com', 22)] = _rsaFingerprint;

        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          keyType: _ecdsaType,
          fingerprintBytes: _bytesOf(_ecdsaFingerprint),
        );

        expect(result.knownKeyTypes, isEmpty);
      });
    });

    test('tracks the same host on a different port independently', () async {
      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_ed25519Fingerprint),
      );

      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 2222,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_rsaFingerprint),
      );

      expect(result.verdict, HostKeyVerdict.firstSeen);
    });

    test('treats different hosts on the same port independently', () async {
      await service.verifyHostKey(
        host: 'alpha.example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_ed25519Fingerprint),
      );

      final result = await service.verifyHostKey(
        host: 'bravo.example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_rsaFingerprint),
      );

      expect(result.verdict, HostKeyVerdict.firstSeen);
    });
  });

  group('acceptNewKeyType', () {
    setUp(() {
      storage.values[_v2Key('example.com', 22, _ed25519Type)] =
          _ed25519Fingerprint;
    });

    test('pins the new key type under the versioned key', () async {
      await service.acceptNewKeyType(
        host: 'example.com',
        port: 22,
        keyType: _ecdsaType,
        fingerprint: _ecdsaFingerprint,
      );

      expect(
        storage.values[_v2Key('example.com', 22, _ecdsaType)],
        _ecdsaFingerprint,
      );
    });

    test('adds to the existing key types rather than replacing', () async {
      // The invariant that separates this from `removeHost` and from a
      // mismatch recovery: a server legitimately holds one key PER TYPE,
      // and authorizing a newly offered type says nothing about the ones
      // already on record. Dropping them would silently re-open first
      // contact for every algorithm the user had already vouched for.
      await service.acceptNewKeyType(
        host: 'example.com',
        port: 22,
        keyType: _ecdsaType,
        fingerprint: _ecdsaFingerprint,
      );

      expect(
        storage.values[_v2Key('example.com', 22, _ed25519Type)],
        _ed25519Fingerprint,
      );
      expect(
        storage.values[_v2Key('example.com', 22, _ecdsaType)],
        _ecdsaFingerprint,
      );
    });

    test('the next connection matches instead of gating', () async {
      await service.acceptNewKeyType(
        host: 'example.com',
        port: 22,
        keyType: _ecdsaType,
        fingerprint: _ecdsaFingerprint,
      );

      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ecdsaType,
        fingerprintBytes: _bytesOf(_ecdsaFingerprint),
      );

      expect(result.verdict, HostKeyVerdict.match);
      expect(result.isTrusted, isTrue);
    });

    test('a different key afterwards is a loud mismatch', () async {
      // Authorizing a new type must not soften what happens to it next.
      // Once pinned, that type is held to the same standard as any other.
      await service.acceptNewKeyType(
        host: 'example.com',
        port: 22,
        keyType: _ecdsaType,
        fingerprint: _ecdsaFingerprint,
      );

      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ecdsaType,
        fingerprintBytes: _bytesOf(_rsaFingerprint),
      );

      expect(result.verdict, HostKeyVerdict.mismatch);
      expect(result.isTrusted, isFalse);
    });

    test('refuses a fingerprint that is not in OpenSSH form', () async {
      await expectLater(
        service.acceptNewKeyType(
          host: 'example.com',
          port: 22,
          keyType: _ecdsaType,
          fingerprint: 'MD5:aa:bb:cc',
        ),
        throwsA(isA<HostKeyFingerprintFormatException>()),
      );

      expect(storage.values[_v2Key('example.com', 22, _ecdsaType)], isNull);
    });

    test('leaves a superseded entry for the host alone', () async {
      // Unlike `acceptMigration`, this path never reaches a host carrying
      // a legacy entry — that host migrates instead. Deleting one here
      // anyway would be a trust decision nobody asked for.
      storage.values[_v1Key('example.com', 22)] = _rsaFingerprint;

      await service.acceptNewKeyType(
        host: 'example.com',
        port: 22,
        keyType: _ecdsaType,
        fingerprint: _ecdsaFingerprint,
      );

      expect(storage.values[_v1Key('example.com', 22)], _rsaFingerprint);
    });

    test('leaves other hosts untouched', () async {
      storage.values[_v2Key('other.example.com', 22, _ed25519Type)] =
          _ed25519Fingerprint;

      await service.acceptNewKeyType(
        host: 'example.com',
        port: 22,
        keyType: _ecdsaType,
        fingerprint: _ecdsaFingerprint,
      );

      expect(
        storage.values[_v2Key('other.example.com', 22, _ed25519Type)],
        _ed25519Fingerprint,
      );
    });
  });

  group('acceptMigration', () {
    setUp(() {
      storage.values[_v1Key('example.com', 22)] = _rsaFingerprint;
    });

    test('pins the new fingerprint under the versioned key', () async {
      await service.acceptMigration(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprint: _ed25519Fingerprint,
      );

      expect(
        storage.values[_v2Key('example.com', 22, _ed25519Type)],
        _ed25519Fingerprint,
      );
    });

    test('removes the legacy entry so the prompt does not repeat', () async {
      await service.acceptMigration(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprint: _ed25519Fingerprint,
      );

      expect(storage.values[_v1Key('example.com', 22)], isNull);
    });

    test('the next connection matches instead of migrating', () async {
      await service.acceptMigration(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprint: _ed25519Fingerprint,
      );

      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_ed25519Fingerprint),
      );

      expect(result.verdict, HostKeyVerdict.match);
    });

    test('a different key afterwards is a loud mismatch', () async {
      await service.acceptMigration(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprint: _ed25519Fingerprint,
      );

      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_rsaFingerprint),
      );

      expect(result.verdict, HostKeyVerdict.mismatch);
      expect(result.isTrusted, isFalse);
    });

    test('refuses a fingerprint that is not in OpenSSH form', () async {
      await expectLater(
        service.acceptMigration(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          fingerprint: 'whatever the caller happened to have',
        ),
        throwsA(isA<HostKeyFingerprintFormatException>()),
      );

      expect(storage.values[_v1Key('example.com', 22)], _rsaFingerprint);
    });

    test('leaves other hosts untouched', () async {
      storage.values[_v1Key('other.example.com', 22)] = _rsaFingerprint;

      await service.acceptMigration(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprint: _ed25519Fingerprint,
      );

      expect(storage.values[_v1Key('other.example.com', 22)], _rsaFingerprint);
    });
  });

  group('getFingerprint', () {
    test('returns null for an unknown host', () async {
      expect(
        await service.getFingerprint(
          host: 'unknown.example.com',
          port: 22,
          keyType: _ed25519Type,
        ),
        isNull,
      );
    });

    test('does not read a legacy entry as a current pin', () async {
      storage.values[_v1Key('example.com', 22)] = _rsaFingerprint;

      expect(
        await service.getFingerprint(
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
        ),
        isNull,
      );
    });
  });

  group('removeHost', () {
    test('clears the pin so the host is seen fresh', () async {
      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_ed25519Fingerprint),
      );

      await service.removeHost(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
      );

      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_rsaFingerprint),
      );

      expect(result.verdict, HostKeyVerdict.firstSeen);
    });

    test('also clears a legacy entry for the same host', () async {
      storage.values[_v1Key('example.com', 22)] = _rsaFingerprint;

      await service.removeHost(
        host: 'example.com',
        port: 22,
        keyType: _ed25519Type,
      );

      // Forgetting a host must actually forget it. A surviving legacy
      // entry would greet the user with a migration prompt for the very
      // host they just asked helm to stop trusting.
      expect(storage.values[_v1Key('example.com', 22)], isNull);
    });

    test('is a no-op for an unknown host', () async {
      await expectLater(
        service.removeHost(
          host: 'unknown.example.com',
          port: 22,
          keyType: _ed25519Type,
        ),
        completes,
      );
    });

    test('leaves other hosts untouched', () async {
      await service.verifyHostKey(
        host: 'alpha.example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_ed25519Fingerprint),
      );
      await service.verifyHostKey(
        host: 'bravo.example.com',
        port: 22,
        keyType: _ed25519Type,
        fingerprintBytes: _bytesOf(_rsaFingerprint),
      );

      await service.removeHost(
        host: 'alpha.example.com',
        port: 22,
        keyType: _ed25519Type,
      );

      expect(
        storage.values[_v2Key('bravo.example.com', 22, _ed25519Type)],
        _rsaFingerprint,
      );
    });
  });

  group('listPinnedHosts', () {
    test('is empty when nothing has ever been pinned', () async {
      expect(await service.listPinnedHosts(), isEmpty);
    });

    test('orders pins deterministically, whatever order the store '
        'hands them back in', () async {
      // Inserted deliberately out of order. `readAll()` returns whatever
      // the platform keystore gives it, and Dart maps preserve insertion
      // order, so this stands in for a store that answers in an order
      // helm does not control.
      //
      // Order is not cosmetic on this screen: its one action is to FORGET
      // a host's pinned key. A list that reshuffles between visits is a
      // list where the row under the user's thumb is not the row they
      // meant to tap.
      storage.values[_v2Key('charlie.example.com', 22, _ed25519Type)] =
          _ed25519Fingerprint;
      storage.values[_v2Key('alpha.example.com', 2222, _rsaType)] =
          _rsaFingerprint;
      storage.values[_v2Key('alpha.example.com', 22, _ed25519Type)] =
          _ed25519Fingerprint;

      final pins = await service.listPinnedHosts();

      expect(pins.map((p) => '${p.host}:${p.port}'), [
        'alpha.example.com:22',
        'alpha.example.com:2222',
        'charlie.example.com:22',
      ]);
    });

    test('enumerates several pinned hosts', () async {
      storage.values[_v2Key('alpha.example.com', 22, _ed25519Type)] =
          _ed25519Fingerprint;
      storage.values[_v2Key('bravo.example.com', 2222, _rsaType)] =
          _rsaFingerprint;

      final pins = await service.listPinnedHosts();

      expect(pins, hasLength(2));
      expect(
        pins,
        containsAll([
          isA<PinnedHost>()
              .having((p) => p.host, 'host', 'alpha.example.com')
              .having((p) => p.port, 'port', 22)
              .having((p) => p.keyType, 'keyType', _ed25519Type)
              .having((p) => p.fingerprint, 'fingerprint', _ed25519Fingerprint),
          isA<PinnedHost>()
              .having((p) => p.host, 'host', 'bravo.example.com')
              .having((p) => p.port, 'port', 2222)
              .having((p) => p.keyType, 'keyType', _rsaType)
              .having((p) => p.fingerprint, 'fingerprint', _rsaFingerprint),
        ]),
      );
    });

    test('parses an IPv6 host without mangling its colons', () async {
      // A real Tailscale CGNAT-range literal, the same shape the codebase
      // already uses elsewhere for IPv6 test data (see
      // `host_diagnostics_test.dart`). Parsing from the right is what this
      // pins: splitting `<host>:<port>:<keyType>` left-to-right would cut
      // this host off after its first colon.
      const ipv6Host = 'fd7a:115c:a1e0::1';
      storage.values[_v2Key(ipv6Host, 22, _ed25519Type)] = _ed25519Fingerprint;

      final pins = await service.listPinnedHosts();

      expect(pins, hasLength(1));
      expect(pins.single.host, ipv6Host);
      expect(pins.single.port, 22);
      expect(pins.single.keyType, _ed25519Type);
      expect(pins.single.fingerprint, _ed25519Fingerprint);
    });

    test('surfaces a legacy v1 pin, distinguishable from a v2 one', () async {
      storage.values[_v1Key('old.example.com', 22)] = _rsaFingerprint;

      final pins = await service.listPinnedHosts();

      expect(pins, hasLength(1));
      final pin = pins.single;
      expect(pin.host, 'old.example.com');
      expect(pin.port, 22);
      // No key type: a v1 pin predates the storage key carrying one, so
      // there is nothing to report — not an unknown among several, there
      // is no key type at all.
      expect(pin.keyType, isNull);
      expect(pin.isLegacy, isTrue);
      expect(pin.fingerprint, _rsaFingerprint);
    });

    test('a v2 pin is never also reported as a legacy pin, even though its '
        'key starts with the legacy prefix', () async {
      // `helm_known_host_v2_` begins with `helm_known_host_` — the exact
      // overlap `_pinnedKeyTypes` warns about. A naive "does this key
      // start with the v1 prefix" scan would match this v2 entry too
      // and report the same host twice, once correctly and once
      // mangled (its "port" would actually be `<realPort>:<keyType>`).
      storage.values[_v2Key('example.com', 22, _ed25519Type)] =
          _ed25519Fingerprint;

      final pins = await service.listPinnedHosts();

      expect(pins, hasLength(1));
      expect(pins.single.isLegacy, isFalse);
      expect(pins.single.port, 22);
      expect(pins.single.keyType, _ed25519Type);
    });

    test('a migrated host with a leftover legacy entry reports both, not a '
        'merged or duplicated one', () async {
      // The interrupted-`acceptMigration` state: the v2 write landed and
      // the v1 delete did not. Both are real, distinct records and the
      // view must show both rather than collapsing or losing one.
      storage.values[_v2Key('example.com', 22, _ed25519Type)] =
          _ed25519Fingerprint;
      storage.values[_v1Key('example.com', 22)] = _rsaFingerprint;

      final pins = await service.listPinnedHosts();

      expect(pins, hasLength(2));
      expect(pins.where((p) => p.isLegacy), hasLength(1));
      expect(pins.where((p) => !p.isLegacy), hasLength(1));
    });

    test('propagates a storage failure rather than reporting empty', () {
      // A store that could not be read is not evidence that it holds
      // nothing. Collapsing the two would show "no trusted hosts" when
      // the honest answer is "could not ask" — exactly the trap
      // `_pinnedKeyTypes` already refuses for the connection path.
      final failing = _FailingSecureStorage();
      final failingService = KnownHostsService(storage: failing);

      expect(
        () => failingService.listPinnedHosts(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('HostKeyVerification.isTrusted', () {
    test('is true only for firstSeen and match', () {
      const trusted = [HostKeyVerdict.firstSeen, HostKeyVerdict.match];

      for (final verdict in HostKeyVerdict.values) {
        final verification = HostKeyVerification(
          verdict: verdict,
          host: 'example.com',
          port: 22,
          keyType: _ed25519Type,
          receivedFingerprint: _ed25519Fingerprint,
        );

        expect(
          verification.isTrusted,
          trusted.contains(verdict),
          reason: 'verdict $verdict',
        );
      }
    });
  });
}
