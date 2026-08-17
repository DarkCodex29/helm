import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';

import '../../../helpers/fake_secure_storage.dart';

void main() {
  late FakeSecureStorage storage;
  late SSHKeyService service;

  setUp(() {
    storage = FakeSecureStorage();
    service = SSHKeyService(storage: storage);
  });

  group('hasKeyPair', () {
    test('is false before a key pair is generated', () async {
      expect(await service.hasKeyPair(), isFalse);
    });

    test('is true after a key pair is generated', () async {
      await service.generateAndSave();

      expect(await service.hasKeyPair(), isTrue);
    });
  });

  group('generateAndSave', () {
    test('writes both the private and the public key', () async {
      await service.generateAndSave();

      expect(storage.values[AppConstants.sshPrivateKeyStorageKey], isNotNull);
      expect(storage.values[AppConstants.sshPublicKeyStorageKey], isNotNull);
    });

    test('stores an OpenSSH private key PEM', () async {
      await service.generateAndSave();

      final pem = await service.getPrivateKey();
      expect(pem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
      expect(pem, contains('-----END OPENSSH PRIVATE KEY-----'));
    });

    test('produces a well-formed ssh-ed25519 public key', () async {
      await service.generateAndSave(comment: 'helm-test');

      final publicKey = await service.getPublicKey();
      final parts = publicKey!.split(' ');

      expect(parts, hasLength(3));
      expect(parts[0], 'ssh-ed25519');
      expect(parts[2], 'helm-test');

      // Wire format: uint32 len + "ssh-ed25519" + uint32 len + 32-byte key.
      final blob = base64.decode(parts[1]);
      expect(blob, hasLength(4 + 11 + 4 + 32));
      expect(utf8.decode(blob.sublist(4, 15)), 'ssh-ed25519');
    });

    test('defaults the public key comment to helm', () async {
      await service.generateAndSave();

      final publicKey = await service.getPublicKey();
      expect(publicKey!.split(' ').last, 'helm');
    });

    test('generates a different key pair on every call', () async {
      await service.generateAndSave();
      final first = await service.getPublicKey();

      await service.generateAndSave();
      final second = await service.getPublicKey();

      expect(first, isNot(second));
    });
  });

  group('getKeyPairs', () {
    test('returns an empty list when no key exists', () async {
      expect(await service.getKeyPairs(), isEmpty);
    });

    test('parses the generated PEM back into a usable key pair', () async {
      await service.generateAndSave();

      expect(await service.getKeyPairs(), isNotEmpty);
    });
  });

  group('getPrivateKey / getPublicKey', () {
    test('both return null when nothing has been generated', () async {
      expect(await service.getPrivateKey(), isNull);
      expect(await service.getPublicKey(), isNull);
    });
  });

  group('deleteKeyPair', () {
    test('clears both stored entries', () async {
      await service.generateAndSave();

      await service.deleteKeyPair();

      expect(
        storage.values.containsKey(AppConstants.sshPrivateKeyStorageKey),
        isFalse,
      );
      expect(
        storage.values.containsKey(AppConstants.sshPublicKeyStorageKey),
        isFalse,
      );
      expect(await service.hasKeyPair(), isFalse);
    });

    test('is a no-op when no key pair exists', () async {
      await expectLater(service.deleteKeyPair(), completes);
    });
  });
}
