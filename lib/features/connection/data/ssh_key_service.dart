import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:pinenacl/ed25519.dart' as pinenacl;

/// Manages generation and secure storage of the app's SSH key pair.
///
/// Uses Ed25519 which is supported by dartssh2 and recommended for modern SSH.
/// Private key is stored in flutter_secure_storage (Keychain on iOS, Keystore on Android).
class SSHKeyService {
  SSHKeyService({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
            aOptions: AndroidOptions(),
          );

  final FlutterSecureStorage _storage;
  static final _log = HelmLogger('SSHKeyService');

  // ── Public API ─────────────────────────────────────────────────────────

  /// Returns true if a key pair has already been generated and saved.
  Future<bool> hasKeyPair() async {
    final key = await _storage.read(key: AppConstants.sshPrivateKeyStorageKey);
    return key != null;
  }

  /// Generates a new Ed25519 key pair and stores it securely.
  ///
  /// Creates an OpenSSH private key PEM and the corresponding
  /// `ssh-ed25519 <base64> helm` public key string.
  ///
  /// Overwrites any existing key pair.
  Future<void> generateAndSave({String comment = 'helm'}) async {
    _log.i('Generating new Ed25519 key pair');

    // 1. Generate a random Ed25519 signing key (32-byte seed → 64-byte secret)
    final signingKey = pinenacl.SigningKey.generate();
    final seed = signingKey.seed.asTypedList;
    final publicKeyBytes = signingKey.verifyKey.asTypedList;

    // 2. Build OpenSSH private key via dartssh2's internal model
    //    privateKey in OpenSSHEd25519KeyPair format = seed + publicKey (64 bytes)
    final privateKeyBlob = Uint8List(64)
      ..setRange(0, 32, seed)
      ..setRange(32, 64, publicKeyBytes);

    final keyPair = OpenSSHEd25519KeyPair(
      publicKeyBytes, // 32-byte public key
      privateKeyBlob, // 64-byte signing key (seed + pubkey)
      comment,
    );

    final privatePem = keyPair.toPem();
    final publicKeyString = _encodePublicKey(publicKeyBytes, comment);

    await _storage.write(
      key: AppConstants.sshPrivateKeyStorageKey,
      value: privatePem,
    );
    await _storage.write(
      key: AppConstants.sshPublicKeyStorageKey,
      value: publicKeyString,
    );
    _log.i('Key pair saved to secure storage');
  }

  /// Retrieves the stored private key PEM string, or null if not found.
  Future<String?> getPrivateKey() async {
    return _storage.read(key: AppConstants.sshPrivateKeyStorageKey);
  }

  /// Retrieves the stored public key in OpenSSH authorized_keys format, or null if not found.
  Future<String?> getPublicKey() async {
    return _storage.read(key: AppConstants.sshPublicKeyStorageKey);
  }

  /// Returns [SSHKeyPair] instances for use with [SSHClient].
  /// Returns an empty list if no key pair has been generated.
  Future<List<SSHKeyPair>> getKeyPairs() async {
    final pem = await getPrivateKey();
    if (pem == null) return [];
    return SSHKeyPair.fromPem(pem);
  }

  /// Deletes the stored key pair.
  Future<void> deleteKeyPair() async {
    await _storage.delete(key: AppConstants.sshPrivateKeyStorageKey);
    await _storage.delete(key: AppConstants.sshPublicKeyStorageKey);
    _log.i('Key pair deleted');
  }

  // ── Private helpers ────────────────────────────────────────────────────

  /// Encodes the raw 32-byte Ed25519 public key into OpenSSH authorized_keys format:
  /// `ssh-ed25519 <base64-encoded-blob> <comment>`
  String _encodePublicKey(Uint8List rawPublicKey, String comment) {
    // OpenSSH public key wire format:
    //   4-byte length-prefixed "ssh-ed25519" + 4-byte length-prefixed 32-byte key
    final algName = 'ssh-ed25519';
    final algBytes = utf8.encode(algName);

    final blob = BytesBuilder();
    blob.add(_uint32(algBytes.length));
    blob.add(algBytes);
    blob.add(_uint32(rawPublicKey.length));
    blob.add(rawPublicKey);

    final encoded = base64.encode(blob.toBytes());
    return '$algName $encoded $comment';
  }

  /// Big-endian uint32 bytes.
  static List<int> _uint32(int value) => [
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];
}
