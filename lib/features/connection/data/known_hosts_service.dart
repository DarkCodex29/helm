import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/utils/logger.dart';

/// Outcome of comparing a presented host key against the trust store.
enum HostKeyVerdict {
  /// No fingerprint was on record for this host. Under Trust On First Use the
  /// key is now pinned and the connection may proceed.
  firstSeen,

  /// The presented key matches the pinned fingerprint.
  match,

  /// The presented key differs from the pinned fingerprint. The connection
  /// must be aborted — this is what a man-in-the-middle looks like.
  mismatch,
}

/// Result of a host key verification, including both fingerprints so callers
/// can render an actionable message.
class HostKeyVerification {
  const HostKeyVerification({
    required this.verdict,
    required this.host,
    required this.port,
    required this.receivedFingerprint,
    this.storedFingerprint,
  });

  final HostKeyVerdict verdict;
  final String host;
  final int port;

  /// Fingerprint of the key the server just presented.
  final String receivedFingerprint;

  /// Fingerprint previously pinned for this host, or null on first contact.
  final String? storedFingerprint;

  /// Whether the connection is allowed to continue.
  bool get isTrusted => verdict != HostKeyVerdict.mismatch;
}

/// Thrown when a server presents a host key that contradicts the pinned one.
class HostKeyMismatchException implements Exception {
  const HostKeyMismatchException({
    required this.host,
    required this.port,
    required this.expectedFingerprint,
    required this.receivedFingerprint,
  });

  final String host;
  final int port;

  /// The fingerprint Helm pinned the first time it saw this host.
  final String expectedFingerprint;

  /// The fingerprint the server presented on this attempt.
  final String receivedFingerprint;

  @override
  String toString() =>
      'HostKeyMismatchException($host:$port, '
      'expected: $expectedFingerprint, received: $receivedFingerprint)';
}

/// Trust On First Use (TOFU) store for SSH host key fingerprints.
///
/// The first time a host is contacted its key is pinned. Every later
/// connection to the same `host:port` must present the same key, otherwise the
/// connection is refused. This is the same trust model OpenSSH uses for
/// `~/.ssh/known_hosts`, and it is what stops an attacker on the network path
/// from impersonating the server.
///
/// Fingerprints live in [FlutterSecureStorage] (Keychain on iOS, Keystore on
/// Android) alongside the app's SSH key pair.
class KnownHostsService {
  KnownHostsService({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
            aOptions: AndroidOptions(),
          );

  final FlutterSecureStorage _storage;
  static final _log = HelmLogger('KnownHostsService');

  // ── Public API ─────────────────────────────────────────────────────────

  /// Renders [hostKeyBytes] as an OpenSSH-style fingerprint:
  /// `SHA256:<base64 without padding>`.
  static String computeFingerprint(Uint8List hostKeyBytes) {
    final digest = sha256.convert(hostKeyBytes);
    final encoded = base64.encode(digest.bytes).replaceAll(RegExp(r'=+$'), '');
    return 'SHA256:$encoded';
  }

  /// Compares [hostKeyBytes] against the pinned fingerprint for [host]:[port].
  ///
  /// On first contact the fingerprint is pinned and [HostKeyVerdict.firstSeen]
  /// is returned. A mismatch never overwrites the pinned value — recovering
  /// from a legitimate server rebuild requires an explicit [removeHost].
  Future<HostKeyVerification> verifyHostKey({
    required String host,
    required int port,
    required Uint8List hostKeyBytes,
  }) async {
    final received = computeFingerprint(hostKeyBytes);
    final stored = await getFingerprint(host: host, port: port);

    if (stored == null) {
      await saveFingerprint(host: host, port: port, fingerprint: received);
      _log.i('Pinned host key for $host:$port on first contact ($received)');
      return HostKeyVerification(
        verdict: HostKeyVerdict.firstSeen,
        host: host,
        port: port,
        receivedFingerprint: received,
      );
    }

    if (stored == received) {
      return HostKeyVerification(
        verdict: HostKeyVerdict.match,
        host: host,
        port: port,
        receivedFingerprint: received,
        storedFingerprint: stored,
      );
    }

    _log.e(
      'Host key mismatch for $host:$port — '
      'expected $stored but received $received',
    );
    return HostKeyVerification(
      verdict: HostKeyVerdict.mismatch,
      host: host,
      port: port,
      receivedFingerprint: received,
      storedFingerprint: stored,
    );
  }

  /// Returns the pinned fingerprint for [host]:[port], or null if unknown.
  Future<String?> getFingerprint({
    required String host,
    required int port,
  }) async {
    return _storage.read(key: _storageKey(host, port));
  }

  /// Pins [fingerprint] for [host]:[port], replacing any previous value.
  Future<void> saveFingerprint({
    required String host,
    required int port,
    required String fingerprint,
  }) async {
    await _storage.write(key: _storageKey(host, port), value: fingerprint);
  }

  /// Forgets the pinned fingerprint for [host]:[port].
  ///
  /// The next connection is treated as a first contact. This is the escape
  /// hatch for a server that was legitimately rebuilt or re-keyed.
  Future<void> removeHost({required String host, required int port}) async {
    await _storage.delete(key: _storageKey(host, port));
    _log.i('Removed pinned host key for $host:$port');
  }

  // ── Private helpers ────────────────────────────────────────────────────

  /// Host identity is `host:port`, so the same hostname on another port is a
  /// separate trust entry.
  String _storageKey(String host, int port) =>
      '${AppConstants.knownHostStorageKeyPrefix}$host:$port';
}
