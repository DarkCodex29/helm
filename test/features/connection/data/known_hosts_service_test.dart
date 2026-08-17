import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';

import '../../../helpers/fake_secure_storage.dart';

void main() {
  late FakeSecureStorage storage;
  late KnownHostsService service;

  setUp(() {
    storage = FakeSecureStorage();
    service = KnownHostsService(storage: storage);
  });

  final keyA = Uint8List.fromList(utf8.encode('host-key-alpha'));
  final keyB = Uint8List.fromList(utf8.encode('host-key-bravo'));

  group('computeFingerprint', () {
    test('formats the digest as SHA256:<base64-without-padding>', () {
      final fingerprint = KnownHostsService.computeFingerprint(Uint8List(0));

      // Well-known SHA-256 of the empty input, base64 encoded with the
      // trailing '=' padding stripped, exactly as OpenSSH renders it.
      expect(fingerprint, 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU');
    });

    test('never contains base64 padding characters', () {
      final fingerprint = KnownHostsService.computeFingerprint(keyA);

      expect(fingerprint, startsWith('SHA256:'));
      expect(fingerprint, isNot(contains('=')));
    });

    test('is deterministic for the same bytes', () {
      expect(
        KnownHostsService.computeFingerprint(keyA),
        KnownHostsService.computeFingerprint(Uint8List.fromList(keyA)),
      );
    });

    test('differs for different bytes', () {
      expect(
        KnownHostsService.computeFingerprint(keyA),
        isNot(KnownHostsService.computeFingerprint(keyB)),
      );
    });
  });

  group('verifyHostKey', () {
    test(
      'returns firstSeen and stores the fingerprint on first contact',
      () async {
        final result = await service.verifyHostKey(
          host: 'example.com',
          port: 22,
          hostKeyBytes: keyA,
        );

        expect(result.verdict, HostKeyVerdict.firstSeen);
        expect(result.isTrusted, isTrue);
        expect(result.storedFingerprint, isNull);
        expect(
          result.receivedFingerprint,
          KnownHostsService.computeFingerprint(keyA),
        );

        final persisted = await service.getFingerprint(
          host: 'example.com',
          port: 22,
        );
        expect(persisted, KnownHostsService.computeFingerprint(keyA));
      },
    );

    test('returns match when the same host key is presented again', () async {
      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        hostKeyBytes: keyA,
      );

      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        hostKeyBytes: keyA,
      );

      expect(result.verdict, HostKeyVerdict.match);
      expect(result.isTrusted, isTrue);
      expect(
        result.storedFingerprint,
        KnownHostsService.computeFingerprint(keyA),
      );
    });

    test('returns mismatch when a different host key is presented', () async {
      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        hostKeyBytes: keyA,
      );

      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        hostKeyBytes: keyB,
      );

      expect(result.verdict, HostKeyVerdict.mismatch);
      expect(result.isTrusted, isFalse);
      expect(
        result.storedFingerprint,
        KnownHostsService.computeFingerprint(keyA),
      );
      expect(
        result.receivedFingerprint,
        KnownHostsService.computeFingerprint(keyB),
      );
    });

    test('does not overwrite the stored fingerprint on mismatch', () async {
      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        hostKeyBytes: keyA,
      );

      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        hostKeyBytes: keyB,
      );

      expect(
        await service.getFingerprint(host: 'example.com', port: 22),
        KnownHostsService.computeFingerprint(keyA),
      );
    });

    test('tracks the same host on a different port independently', () async {
      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        hostKeyBytes: keyA,
      );

      // A different port is a different server identity, so a different key
      // there must still be treated as a first contact, not a mismatch.
      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 2222,
        hostKeyBytes: keyB,
      );

      expect(result.verdict, HostKeyVerdict.firstSeen);
      expect(
        await service.getFingerprint(host: 'example.com', port: 22),
        KnownHostsService.computeFingerprint(keyA),
      );
      expect(
        await service.getFingerprint(host: 'example.com', port: 2222),
        KnownHostsService.computeFingerprint(keyB),
      );
    });

    test('treats different hosts on the same port independently', () async {
      await service.verifyHostKey(
        host: 'alpha.example.com',
        port: 22,
        hostKeyBytes: keyA,
      );

      final result = await service.verifyHostKey(
        host: 'bravo.example.com',
        port: 22,
        hostKeyBytes: keyB,
      );

      expect(result.verdict, HostKeyVerdict.firstSeen);
    });
  });

  group('saveFingerprint', () {
    test('persists under a namespaced host:port storage key', () async {
      await service.saveFingerprint(
        host: 'example.com',
        port: 2222,
        fingerprint: 'SHA256:abc',
      );

      expect(
        storage
            .values['${AppConstants.knownHostStorageKeyPrefix}example.com:2222'],
        'SHA256:abc',
      );
    });

    test('replaces an existing fingerprint', () async {
      await service.saveFingerprint(
        host: 'example.com',
        port: 22,
        fingerprint: 'SHA256:old',
      );
      await service.saveFingerprint(
        host: 'example.com',
        port: 22,
        fingerprint: 'SHA256:new',
      );

      expect(
        await service.getFingerprint(host: 'example.com', port: 22),
        'SHA256:new',
      );
    });
  });

  group('getFingerprint', () {
    test('returns null for an unknown host', () async {
      expect(
        await service.getFingerprint(host: 'unknown.example.com', port: 22),
        isNull,
      );
    });
  });

  group('removeHost', () {
    test('clears the stored fingerprint so the host is seen fresh', () async {
      await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        hostKeyBytes: keyA,
      );

      await service.removeHost(host: 'example.com', port: 22);

      expect(
        await service.getFingerprint(host: 'example.com', port: 22),
        isNull,
      );

      // After removal a rebuilt server presenting a new key is accepted again.
      final result = await service.verifyHostKey(
        host: 'example.com',
        port: 22,
        hostKeyBytes: keyB,
      );
      expect(result.verdict, HostKeyVerdict.firstSeen);
    });

    test('is a no-op for an unknown host', () async {
      await expectLater(
        service.removeHost(host: 'unknown.example.com', port: 22),
        completes,
      );
    });

    test('leaves other hosts untouched', () async {
      await service.verifyHostKey(
        host: 'alpha.example.com',
        port: 22,
        hostKeyBytes: keyA,
      );
      await service.verifyHostKey(
        host: 'bravo.example.com',
        port: 22,
        hostKeyBytes: keyB,
      );

      await service.removeHost(host: 'alpha.example.com', port: 22);

      expect(
        await service.getFingerprint(host: 'bravo.example.com', port: 22),
        KnownHostsService.computeFingerprint(keyB),
      );
    });
  });
}
