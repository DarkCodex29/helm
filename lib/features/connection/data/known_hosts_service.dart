import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/utils/logger.dart';

/// Outcome of comparing a presented host key against the trust store.
enum HostKeyVerdict {
  /// No fingerprint was on record for this host and key type. Under Trust
  /// On First Use the key is now pinned and the connection may proceed.
  firstSeen,

  /// The presented key matches the pinned fingerprint.
  match,

  /// The presented key differs from the pinned fingerprint. The connection
  /// must be aborted — this is what a man-in-the-middle looks like.
  mismatch,

  /// A fingerprint IS on record, but it was written under the superseded
  /// scheme described in [AppConstants.knownHostStorageKeyPrefix], so it
  /// cannot be compared against anything this build computes.
  ///
  /// Deliberately NOT [mismatch], and the distinction is the whole reason
  /// this value exists. Every host pinned by an older build reaches this
  /// state exactly once, and routing that through the interception alarm
  /// would fire helm's loudest warning at a fleet of servers whose keys
  /// never changed — which is how a security warning becomes noise the
  /// user learns to click past. It is equally not [firstSeen]: there is a
  /// prior trust decision here, helm simply cannot read it, and silently
  /// re-pinning would make an unauthenticated trust decision on the user's
  /// behalf.
  ///
  /// Named for the finding rather than the remedy — helm cannot verify
  /// this pin — in the same spirit as `MultiplexerUnverified` and
  /// `AttachExitUnknown`: what is unknown is reported as unknown, never
  /// dressed up as either an answer or an alarm.
  ///
  /// Not trusted (see [HostKeyVerification.isTrusted]). Resolving it takes
  /// an explicit [KnownHostsService.acceptMigration].
  unverifiablePin,

  /// This host:port is already pinned under one or more OTHER key types,
  /// and has never presented this one.
  ///
  /// Exists because adding `<keyType>` to the storage key — see
  /// [AppConstants.knownHostV2StorageKeyPrefix] — opened a downgrade path
  /// underneath it. Trust became per key type, so an algorithm never seen
  /// before has no entry, and an absent entry used to mean first contact.
  /// An attacker on the path who controls algorithm negotiation can
  /// advertise ONLY a type the host has never presented — offering just
  /// `ecdsa-sha2-nistp256` to a host helm knows by `ssh-ed25519` — and
  /// their key would be pinned with nothing shown to the user. Before the
  /// key type was in the storage key, any key change was loud; this verdict
  /// is what keeps that true.
  ///
  /// Deliberately NOT [firstSeen]. There is nothing "first" about a host
  /// helm has already pinned, and [firstSeen] is silent by design.
  ///
  /// Deliberately NOT [mismatch] either. A newly offered key type is
  /// usually legitimate — an administrator adds Ed25519 beside an ageing
  /// RSA key, a server is re-keyed, or dartssh2 reorders its preferences
  /// and negotiates something else. No pinned fingerprint has been
  /// contradicted, so raising the interception alarm would spend helm's
  /// loudest warning on routine server maintenance.
  ///
  /// This is the same class of gate as [unverifiablePin]: an authorization
  /// the user must give once, not an alarm. OpenSSH draws the line in the
  /// same place — its `known_hosts` is per key type too, and it does not
  /// silently accept an unknown type for a host it already knows.
  ///
  /// Not trusted (see [HostKeyVerification.isTrusted]). Resolving it takes
  /// an explicit [KnownHostsService.acceptNewKeyType], which ADDS the type
  /// and leaves every existing pin in place.
  unpinnedKeyType,
}

/// Result of a host key verification, including both fingerprints so callers
/// can render an actionable message.
class HostKeyVerification {
  const HostKeyVerification({
    required this.verdict,
    required this.host,
    required this.port,
    required this.keyType,
    required this.receivedFingerprint,
    this.storedFingerprint,
    this.knownKeyTypes = const [],
  });

  final HostKeyVerdict verdict;
  final String host;
  final int port;

  /// The host key algorithm this verdict is about, e.g. `ssh-ed25519`.
  ///
  /// Part of the result rather than an incidental input because trust is
  /// pinned per key type — see
  /// [AppConstants.knownHostV2StorageKeyPrefix] — and because a surface
  /// asking the user to verify a fingerprint has to tell them WHICH key
  /// file on the server to compare it against.
  final String keyType;

  /// Fingerprint of the key the server just presented, in OpenSSH's
  /// `SHA256:<base64>` form.
  final String receivedFingerprint;

  /// Fingerprint previously recorded for this host, or null on first
  /// contact.
  ///
  /// For [HostKeyVerdict.mismatch] this is directly comparable to
  /// [receivedFingerprint]. For [HostKeyVerdict.unverifiablePin] it is
  /// the superseded value, which is NOT comparable to anything — see
  /// [HostKeyVerdict.unverifiablePin].
  final String? storedFingerprint;

  /// The key types this host:port is ALREADY pinned under, sorted, never
  /// including [keyType].
  ///
  /// Populated for [HostKeyVerdict.unpinnedKeyType] and empty otherwise.
  /// A surface asking the user to authorize a newly offered algorithm has
  /// to be able to say which ones the host was known by, because that
  /// contrast is the entire reason the question is being asked — "this
  /// host has always presented ssh-ed25519 and is now offering
  /// ecdsa-sha2-nistp256" is something a user can act on, where a bare
  /// fingerprint is not.
  ///
  /// Sorted so the copy is stable between launches rather than ordered by
  /// whatever sequence the keychain happened to enumerate.
  ///
  /// Type names only, never the fingerprints behind them. Those belong to
  /// different keys and printing them next to [receivedFingerprint] would
  /// stage a before/after comparison between values that are SUPPOSED to
  /// differ — the same trap [HostKeyMigrationRequiredException] keeps its
  /// superseded value behind a disclosure to avoid.
  final List<String> knownKeyTypes;

  /// Whether the connection is allowed to continue.
  ///
  /// Enumerated positively rather than as "not a mismatch". The negative
  /// form silently admitted every verdict added after it, and
  /// [HostKeyVerdict.unverifiablePin] is exactly such a verdict: it is not
  /// an interception, and it is still not something to connect through.
  bool get isTrusted =>
      verdict == HostKeyVerdict.firstSeen || verdict == HostKeyVerdict.match;
}

/// Thrown when a value that should be an OpenSSH `SHA256:<base64>`
/// fingerprint is not one.
///
/// This is a fail-closed guard, not an error report. dartssh2 has already
/// changed the meaning of the bytes it passes to `onVerifyHostKey` once —
/// 2.16.0 handed over a raw MD5 digest, 3.3.1 hands over the UTF-8 of the
/// OpenSSH string — and helm pinned the difference without noticing.
/// Refusing to store anything that is not recognisably a fingerprint is
/// what stops the next such change from silently pinning garbage as if it
/// were a trust decision.
class HostKeyFingerprintFormatException implements Exception {
  const HostKeyFingerprintFormatException(this.reason);

  /// What was wrong, for logs. Never contains the rejected value: it is
  /// unvalidated bytes from the network, and this string reaches the log.
  final String reason;

  @override
  String toString() => 'HostKeyFingerprintFormatException($reason)';
}

/// Thrown when a server presents a host key that contradicts the pinned one.
class HostKeyMismatchException implements Exception {
  const HostKeyMismatchException({
    required this.host,
    required this.port,
    required this.keyType,
    required this.expectedFingerprint,
    required this.receivedFingerprint,
  });

  final String host;
  final int port;

  /// The host key algorithm, e.g. `ssh-ed25519`.
  final String keyType;

  /// The fingerprint Helm pinned the first time it saw this host.
  final String expectedFingerprint;

  /// The fingerprint the server presented on this attempt.
  final String receivedFingerprint;

  @override
  String toString() =>
      'HostKeyMismatchException($host:$port $keyType, '
      'expected: $expectedFingerprint, received: $receivedFingerprint)';
}

/// A connection helm refused because the host key needs an explicit,
/// one-off authorization from the user.
///
/// Groups the states that are NOT alarms but are also not trust: helm found
/// something it cannot resolve on the user's behalf, so it asks. Every
/// subtype shares one pipeline — one pending-prompt notifier, one accept
/// path, one surface — because they share one answer: show the fingerprint,
/// take a yes or a no, write nothing without it.
///
/// [HostKeyMismatchException] is deliberately NOT a member. A mismatch is
/// an alarm, and admitting it here would give it a one-tap trust button by
/// inheritance. Sealed rather than open for that reason: adding a subtype
/// is a decision that has to be made in this file, next to this paragraph,
/// and it makes every `switch` over the hierarchy exhaustive so the
/// compiler names the surfaces a new gate has to teach.
sealed class HostKeyAuthorizationRequiredException implements Exception {
  const HostKeyAuthorizationRequiredException();

  /// The host the user is being asked about.
  String get host;
  int get port;

  /// The host key algorithm, e.g. `ssh-ed25519`. Determines which key file
  /// on the server the user should run `ssh-keygen -lf` against.
  String get keyType;

  /// What the server presented, in OpenSSH form — the value the user can
  /// actually compare against the server.
  String get receivedFingerprint;
}

/// Thrown when a host was pinned by a build that stored fingerprints helm
/// can no longer compare, so the user has to re-authorize it once.
///
/// Named for what the CALLER must do, where [HostKeyVerdict.unverifiablePin]
/// is named for what the store FOUND. Those are two different jobs: the
/// verdict is a fact about a record, this is a demand on a connection.
///
/// Deliberately not a subtype of, or in any way conflated with,
/// [HostKeyMismatchException]. A migration is not an attack, and the copy,
/// the colour and the default action all differ because of it.
class HostKeyMigrationRequiredException
    extends HostKeyAuthorizationRequiredException {
  const HostKeyMigrationRequiredException({
    required this.host,
    required this.port,
    required this.keyType,
    required this.receivedFingerprint,
    required this.legacyFingerprint,
  });

  @override
  final String host;
  @override
  final int port;

  @override
  final String keyType;

  @override
  final String receivedFingerprint;

  /// The superseded stored value. Kept for the record, NOT for comparison:
  /// it is `SHA256(MD5(host key))` and matches nothing a user could run.
  /// Surfaces must not invite a comparison against it.
  final String legacyFingerprint;

  @override
  String toString() =>
      'HostKeyMigrationRequiredException($host:$port $keyType, '
      'received: $receivedFingerprint)';
}

/// Thrown when a known host presents a key type it has never presented
/// before, so the user has to authorize that algorithm once.
///
/// Named for what the CALLER must do, where [HostKeyVerdict.unpinnedKeyType]
/// is named for what the store FOUND — the same split
/// [HostKeyMigrationRequiredException] makes, and for the same reason: the
/// verdict is a fact about a record, this is a demand on a connection.
///
/// Sibling to that exception rather than a variant of it. Both ask for one
/// authorization, but they ask about different things and must not borrow
/// each other's explanation: a migration is about a value helm can no
/// longer read, while this is about a key helm has never seen. Telling a
/// user their stored fingerprint became unreadable, when the truth is that
/// their server started offering ECDSA, would send them looking for a
/// problem that is not there.
///
/// Deliberately not conflated with [HostKeyMismatchException] either. No
/// pinned fingerprint has been contradicted here — see
/// [HostKeyVerdict.unpinnedKeyType] for why that distinction is what keeps
/// the interception alarm meaningful.
class HostKeyTypeAuthorizationRequiredException
    extends HostKeyAuthorizationRequiredException {
  const HostKeyTypeAuthorizationRequiredException({
    required this.host,
    required this.port,
    required this.keyType,
    required this.receivedFingerprint,
    required this.knownKeyTypes,
  });

  @override
  final String host;
  @override
  final int port;

  /// The NEWLY offered algorithm — the one being authorized, and the one
  /// whose key file the verification command points at.
  @override
  final String keyType;

  @override
  final String receivedFingerprint;

  /// The algorithms this host is already pinned under, sorted and never
  /// including [keyType]. Never empty: without one, this would be an
  /// ordinary first contact. See [HostKeyVerification.knownKeyTypes] for
  /// why the surface needs them and why their fingerprints are not here.
  final List<String> knownKeyTypes;

  @override
  String toString() =>
      'HostKeyTypeAuthorizationRequiredException($host:$port $keyType, '
      'known: ${knownKeyTypes.join(', ')}, '
      'received: $receivedFingerprint)';
}

/// The exact command that prints the server's own fingerprint for
/// [keyType], or null when [keyType] is not one this build recognises.
///
/// Returns a command for the user to RUN ON THE SERVER, through a channel
/// they already trust, to compare against what helm displays. That
/// comparison is only meaningful because helm no longer re-hashes what
/// dartssh2 gives it — see [KnownHostsService.decodeFingerprint].
///
/// Exactly one file per command, because `ssh-keygen -lf` takes exactly one
/// file: verified against OpenSSH, `ssh-keygen -lf a.pub b.pub` answers
/// "Too many arguments." A glob would fail the same way in the user's
/// hands.
///
/// The three RSA entries are three SIGNATURE algorithms over a single host
/// key, so they share `ssh_host_rsa_key.pub`; likewise the three ECDSA
/// curves share `ssh_host_ecdsa_key.pub`. Sending each to a file named
/// after the algorithm would send most of them to files that do not exist.
///
/// Null rather than a guess for anything else. A fabricated path is worse
/// than no instruction: it sends the user to a missing file and undermines
/// the very verification helm is asking them to perform. The mapping covers
/// dartssh2's whole `SSHHostkeyType` set, so null means the library grew a
/// new algorithm, not that this list was left incomplete.
String? hostKeyVerificationCommand(String keyType) {
  final file = switch (keyType) {
    'ssh-ed25519' => 'ssh_host_ed25519_key.pub',
    'ssh-rsa' || 'rsa-sha2-256' || 'rsa-sha2-512' => 'ssh_host_rsa_key.pub',
    'ecdsa-sha2-nistp256' ||
    'ecdsa-sha2-nistp384' ||
    'ecdsa-sha2-nistp521' => 'ssh_host_ecdsa_key.pub',
    _ => null,
  };
  if (file == null) return null;
  return 'ssh-keygen -lf /etc/ssh/$file';
}

/// One pinned host key, as surfaced by [KnownHostsService.listPinnedHosts].
///
/// Covers both storage schemes, because a user deciding whether to forget a
/// pin needs to see a legacy entry just as much as a current one — see
/// [AppConstants.knownHostStorageKeyPrefix]. The two differ in what is
/// actually known about them, and [keyType] carries that: a current pin
/// always has one, a legacy pin never does, because the superseded storage
/// key did not record it.
class PinnedHost {
  const PinnedHost({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.isLegacy,
  });

  final String host;
  final int port;

  /// The key algorithm this pin was recorded under, e.g. `ssh-ed25519`.
  ///
  /// Null exactly when [isLegacy] is true. A legacy entry's storage key is
  /// `<prefix><host>:<port>` — see [AppConstants.knownHostStorageKeyPrefix]
  /// — which has no key-type segment to read, so there is nothing to
  /// report here. Not "unknown among several": there is no key type at
  /// all for this record.
  final String? keyType;

  /// The pinned value, in OpenSSH `SHA256:<base64>` form.
  ///
  /// For a legacy pin this is the superseded value — see
  /// [HostKeyVerdict.unverifiablePin] — shown so the user can tell this
  /// entry apart from another host, NOT so it can be compared against
  /// `ssh-keygen -lf`'s output. Surfaces built on this must not invite
  /// that comparison for a legacy row.
  final String fingerprint;

  /// Whether this pin was written under the superseded, key-type-less
  /// scheme — see [AppConstants.knownHostStorageKeyPrefix].
  ///
  /// A legacy pin still needs forgetting: its user may have rebuilt or
  /// re-keyed the server before ever reconnecting through the current
  /// build, and [KnownHostsService.removeHost] clears both schemes for a
  /// host regardless, so there is one forget action either way — this
  /// field only controls how the row is LABELLED.
  final bool isLegacy;
}

/// Trust On First Use (TOFU) store for SSH host key fingerprints.
///
/// The first time a host is contacted with a given key algorithm, that key
/// is pinned. Every later connection presenting the same algorithm must
/// present the same key, otherwise the connection is refused. This is the
/// same trust model OpenSSH uses for `~/.ssh/known_hosts`, and it is what
/// stops an attacker on the network path from impersonating the server.
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

  /// The exact shape OpenSSH prints and dartssh2 3.3.1 produces.
  ///
  /// A SHA-256 digest is 32 bytes, which base64-encodes to 44 characters
  /// including one `=` of padding; OpenSSH strips the padding, leaving 43.
  /// Anchored at both ends, so trailing junk is a rejection rather than a
  /// prefix match, and restricted to the STANDARD base64 alphabet because
  /// dartssh2 encodes with `base64.encode` — `+` and `/` are legal here and
  /// base64url's `-` and `_` are not.
  static final _openSshFingerprint = RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$');

  // ── Public API ─────────────────────────────────────────────────────────

  /// Reads dartssh2's host key fingerprint bytes as the OpenSSH string
  /// they already are.
  ///
  /// This DECODES; it deliberately computes nothing. dartssh2 >= 3.x hands
  /// `onVerifyHostKey` the UTF-8 bytes of `SHA256:<base64>` — the very
  /// string `ssh-keygen -lf` prints — built by `_hostkeyFingerprint` in
  /// `ssh_transport.dart:47` and passed at `:1771`. Verified empirically
  /// against a real key pair: SHA-256 over the public key blob, base64 with
  /// padding stripped, reproduces `ssh-keygen -lf`'s output byte for byte.
  ///
  /// The predecessor of this method hashed those bytes AGAIN. That was
  /// sound against dartssh2 2.16.0, which passed a raw MD5 digest
  /// (`ssh_transport.dart:1031` in that version) — but under 3.x it
  /// produced `SHA256("SHA256:...")`, destroying the one property that
  /// makes a fingerprint useful: that a human can compare it to the server.
  ///
  /// The prefix is NOT re-added here. It is already in the string, and
  /// re-adding it is a mistake with a shipped precedent: ConnectBot
  /// displayed `SHA256:SHA256:...` to users before correcting it.
  ///
  /// Throws [HostKeyFingerprintFormatException] on anything that is not
  /// recognisably an OpenSSH fingerprint, rather than storing it. See that
  /// class for why the guard exists at all.
  static String decodeFingerprint(Uint8List fingerprintBytes) {
    final String decoded;
    try {
      // Strict on purpose: `allowMalformed` would substitute U+FFFD and
      // turn undecodable bytes into a string that merely fails the shape
      // check below for the wrong reason.
      decoded = utf8.decode(fingerprintBytes);
    } on FormatException {
      throw const HostKeyFingerprintFormatException('not valid UTF-8');
    }

    if (!_openSshFingerprint.hasMatch(decoded)) {
      throw const HostKeyFingerprintFormatException(
        'not an OpenSSH SHA256:<base64> fingerprint',
      );
    }

    return decoded;
  }

  /// Compares the key the server presented against the trust store.
  ///
  /// [fingerprintBytes] is dartssh2's `onVerifyHostKey` argument and
  /// [keyType] its host key algorithm name, e.g. `ssh-ed25519`.
  ///
  /// On first contact — no entry for this host:port under ANY key type,
  /// current or superseded — the fingerprint is pinned and
  /// [HostKeyVerdict.firstSeen] is returned. Only that case is silent.
  /// Every state carrying a prior trust decision is gated: a mismatch, an
  /// unreadable legacy pin, and a key type this host has never presented
  /// all return without writing anything. Recovering from a legitimate
  /// server rebuild requires [removeHost], clearing a legacy pin requires
  /// [acceptMigration], and adding a key type requires [acceptNewKeyType].
  /// All three are explicit user acts.
  ///
  /// The three no-current-pin cases are checked in a fixed order, and the
  /// order encodes what helm can actually prove:
  ///
  /// 1. A superseded entry wins, because it is not key-type-scoped. helm
  ///    cannot tell which algorithm it was written for, so it cannot claim
  ///    the presented type is new — that would assert the one fact it does
  ///    not have. See [HostKeyVerdict.unverifiablePin].
  /// 2. Otherwise a pin under another key type makes this
  ///    [HostKeyVerdict.unpinnedKeyType].
  /// 3. Only with neither is this a genuine first contact.
  ///
  /// Cases 1 and 2 both gate the connection, so the ordering decides which
  /// explanation the user reads, never whether they are asked at all.
  ///
  /// Throws [HostKeyFingerprintFormatException] — and stores nothing — if
  /// the presented value is not an OpenSSH fingerprint.
  Future<HostKeyVerification> verifyHostKey({
    required String host,
    required int port,
    required String keyType,
    required Uint8List fingerprintBytes,
  }) async {
    final received = decodeFingerprint(fingerprintBytes);
    final stored = await getFingerprint(
      host: host,
      port: port,
      keyType: keyType,
    );

    if (stored == null) {
      // Checked only when there is no current pin, so a host that has
      // already migrated is never asked to migrate again — including when
      // a crash between [acceptMigration]'s write and its delete left the
      // legacy entry behind.
      final legacy = await _storage.read(key: _legacyStorageKey(host, port));
      if (legacy != null) {
        _log.w(
          'Host key for $host:$port ($keyType) was pinned in a superseded '
          'format and cannot be compared - re-authorization required',
        );
        return HostKeyVerification(
          verdict: HostKeyVerdict.unverifiablePin,
          host: host,
          port: port,
          keyType: keyType,
          receivedFingerprint: received,
          storedFingerprint: legacy,
        );
      }

      // Reached only when nothing is pinned for THIS key type and no
      // superseded entry exists, so it runs at most once per host and
      // algorithm — never on the hot path where a pin already matches.
      // That placement is what keeps the store-wide scan below affordable.
      final knownKeyTypes = await _pinnedKeyTypes(host: host, port: port);
      if (knownKeyTypes.isNotEmpty) {
        _log.w(
          'Host $host:$port is pinned for ${knownKeyTypes.join(', ')} but '
          'presented $keyType, which has never been seen - explicit '
          'authorization required',
        );
        return HostKeyVerification(
          verdict: HostKeyVerdict.unpinnedKeyType,
          host: host,
          port: port,
          keyType: keyType,
          receivedFingerprint: received,
          // No storedFingerprint: nothing was ever pinned for this key
          // type. The fingerprints under the other types belong to
          // different keys and are not comparable to this one.
          knownKeyTypes: knownKeyTypes,
        );
      }

      await saveFingerprint(
        host: host,
        port: port,
        keyType: keyType,
        fingerprint: received,
      );
      _log.i(
        'Pinned host key for $host:$port ($keyType) on first contact '
        '($received)',
      );
      return HostKeyVerification(
        verdict: HostKeyVerdict.firstSeen,
        host: host,
        port: port,
        keyType: keyType,
        receivedFingerprint: received,
      );
    }

    if (stored == received) {
      return HostKeyVerification(
        verdict: HostKeyVerdict.match,
        host: host,
        port: port,
        keyType: keyType,
        receivedFingerprint: received,
        storedFingerprint: stored,
      );
    }

    _log.e(
      'Host key mismatch for $host:$port ($keyType) - '
      'expected $stored but received $received',
    );
    return HostKeyVerification(
      verdict: HostKeyVerdict.mismatch,
      host: host,
      port: port,
      keyType: keyType,
      receivedFingerprint: received,
      storedFingerprint: stored,
    );
  }

  /// Records the user's decision to trust [fingerprint] for a host whose
  /// previous pin helm could not verify.
  ///
  /// Call ONLY after the user has been shown [fingerprint] and has
  /// explicitly accepted it. Nothing about a [HostKeyVerdict.unverifiablePin]
  /// authorizes this on its own.
  ///
  /// The write happens BEFORE the delete, and that order is the safe one.
  /// Interrupted after the write, the host is correctly pinned and carries
  /// a legacy entry that [verifyHostKey] already ignores. Interrupted after
  /// a delete-first, the host would have no pin at all and the next
  /// connection would silently trust whatever answered — turning a
  /// re-authorization into a first contact.
  ///
  /// Throws [HostKeyFingerprintFormatException] if [fingerprint] is not an
  /// OpenSSH fingerprint, leaving the store untouched.
  Future<void> acceptMigration({
    required String host,
    required int port,
    required String keyType,
    required String fingerprint,
  }) async {
    if (!_openSshFingerprint.hasMatch(fingerprint)) {
      throw const HostKeyFingerprintFormatException(
        'not an OpenSSH SHA256:<base64> fingerprint',
      );
    }

    await saveFingerprint(
      host: host,
      port: port,
      keyType: keyType,
      fingerprint: fingerprint,
    );
    await _storage.delete(key: _legacyStorageKey(host, port));
    _log.i('Re-authorized host key for $host:$port ($keyType) as $fingerprint');
  }

  /// Records the user's decision to trust [fingerprint] as a key type this
  /// host has not presented before.
  ///
  /// Call ONLY after the user has been shown [fingerprint] and has
  /// explicitly accepted it. Nothing about a [HostKeyVerdict.unpinnedKeyType]
  /// authorizes this on its own.
  ///
  /// ADDS a pin; it never replaces or removes one. A server legitimately
  /// holds one host key per algorithm, and authorizing a newly offered
  /// type says nothing about the types already on record — dropping them
  /// would silently re-open first contact for every algorithm the user had
  /// already vouched for, which is the very state this gate exists to
  /// prevent.
  ///
  /// No legacy entry is touched either, unlike [acceptMigration]. A host
  /// carrying one never reaches this verdict — see [verifyHostKey]'s
  /// ordering — so deleting one here could only ever discard a record
  /// nobody asked helm to discard.
  ///
  /// Throws [HostKeyFingerprintFormatException] if [fingerprint] is not an
  /// OpenSSH fingerprint, leaving the store untouched.
  Future<void> acceptNewKeyType({
    required String host,
    required int port,
    required String keyType,
    required String fingerprint,
  }) async {
    if (!_openSshFingerprint.hasMatch(fingerprint)) {
      throw const HostKeyFingerprintFormatException(
        'not an OpenSSH SHA256:<base64> fingerprint',
      );
    }

    await saveFingerprint(
      host: host,
      port: port,
      keyType: keyType,
      fingerprint: fingerprint,
    );
    _log.i('Authorized $keyType host key for $host:$port as $fingerprint');
  }

  /// Returns the pinned fingerprint for this host, port and key type, or
  /// null if none is on record.
  ///
  /// Reads the current scheme only. A superseded entry is deliberately not
  /// reported as a pin — it is not comparable, and returning it here would
  /// hand callers a value they could only misuse.
  Future<String?> getFingerprint({
    required String host,
    required int port,
    required String keyType,
  }) async {
    return _storage.read(key: _storageKey(host, port, keyType));
  }

  /// Pins [fingerprint] for this host, port and key type, replacing any
  /// previous value.
  Future<void> saveFingerprint({
    required String host,
    required int port,
    required String keyType,
    required String fingerprint,
  }) async {
    await _storage.write(
      key: _storageKey(host, port, keyType),
      value: fingerprint,
    );
  }

  /// Every host key pinned by this device, across both storage schemes.
  ///
  /// This is the Settings-facing enumeration: a user who needs to forget a
  /// pin has to be able to SEE what is pinned first, and a keyed read
  /// cannot answer "what hosts exist" any more than [_pinnedKeyTypes]
  /// could answer "what key types exist" for one host. [readAll] is used
  /// for the same reason it is there: it is the only enumeration the
  /// plugin offers.
  ///
  /// Paying [readAll]'s whole-store decryption cost here is acceptable for
  /// a reason specific to WHERE this is called from, not to the cost being
  /// small: this runs only when the user opens the trusted-hosts screen in
  /// Settings, a human-paced, deliberately-navigated-to action taken at
  /// most a handful of times per session — never on the connection path,
  /// never in a loop, and never behind a redirect a user did not choose.
  /// [verifyHostKey]'s equivalent scan earns its keep by running at most
  /// once per host and key type; this one earns its keep by running at
  /// most once per tap on a settings row.
  ///
  /// A current-scheme key is `<v2 prefix><host>:<port>:<keyType>` and a
  /// legacy one is `<v1 prefix><host>:<port>` — see
  /// [AppConstants.knownHostV2StorageKeyPrefix] and
  /// [AppConstants.knownHostStorageKeyPrefix]. Both the prefix check and
  /// the field split have to respect that `helm_known_host_v2_` BEGINS
  /// WITH `helm_known_host_`: a scan for legacy keys that merely checked
  /// the v1 prefix would match every v2 key too, and a naive split would
  /// then read `<port>:<keyType>` as if it were a legacy port. The v2
  /// prefix is checked FIRST and unambiguously (longer, more specific
  /// string), and only a key that is NOT v2 is then tested against the
  /// v1 prefix — the same ordering [verifyHostKey] uses for the pair, and
  /// for the same reason: the two prefixes overlap by construction and
  /// only one direction of the check is safe.
  ///
  /// Fields are parsed from the RIGHT, not the left. The key itself can
  /// contain colons — an IPv6 literal such as `fd7a:115c:a1e0::1` is
  /// nothing unusual over Tailscale, which this app already integrates
  /// with — so a left-to-right split on `:` would cut such a host off at
  /// its first colon and read the rest as port and key type. The v2 shape
  /// is fixed at exactly two trailing fields after the host
  /// (`:<port>:<keyType>`), so the LAST colon-delimited segment is always
  /// the key type, the one before it is always the port, and everything
  /// before THAT — colons included — is the host. The v1 shape has
  /// exactly one trailing field (`:<port>`), so the same right-to-left
  /// reasoning applies with one split instead of two.
  ///
  /// Deliberately unguarded, like [_pinnedKeyTypes]: a failed enumeration
  /// is not evidence that nothing is pinned, and swallowing it here would
  /// show the user "no trusted hosts" when the honest answer is "could
  /// not ask" — the empty-state/failure-state collapse this codebase
  /// never allows. Letting it propagate is what lets the presentation
  /// layer render the failure as unknown rather than as an empty list.
  Future<List<PinnedHost>> listPinnedHosts() async {
    final all = await _storage.readAll();
    final v2Prefix = AppConstants.knownHostV2StorageKeyPrefix;
    final v1Prefix = AppConstants.knownHostStorageKeyPrefix;

    final pins = <PinnedHost>[];
    for (final entry in all.entries) {
      final key = entry.key;
      if (key.startsWith(v2Prefix)) {
        final rest = key.substring(v2Prefix.length);
        final keyTypeSep = rest.lastIndexOf(':');
        if (keyTypeSep < 0) continue; // Not a shape this scheme produces.
        final keyType = rest.substring(keyTypeSep + 1);
        final hostAndPort = rest.substring(0, keyTypeSep);
        final portSep = hostAndPort.lastIndexOf(':');
        if (portSep < 0) continue;
        final host = hostAndPort.substring(0, portSep);
        final port = int.tryParse(hostAndPort.substring(portSep + 1));
        if (port == null) continue;
        pins.add(
          PinnedHost(
            host: host,
            port: port,
            keyType: keyType,
            fingerprint: entry.value,
            isLegacy: false,
          ),
        );
      } else if (key.startsWith(v1Prefix)) {
        // Reached only for keys that are NOT v2, so this never re-reports
        // a v2 entry under the legacy prefix it happens to begin with.
        final hostAndPort = key.substring(v1Prefix.length);
        final portSep = hostAndPort.lastIndexOf(':');
        if (portSep < 0) continue;
        final host = hostAndPort.substring(0, portSep);
        final port = int.tryParse(hostAndPort.substring(portSep + 1));
        if (port == null) continue;
        pins.add(
          PinnedHost(
            host: host,
            port: port,
            keyType: null,
            fingerprint: entry.value,
            isLegacy: true,
          ),
        );
      }
    }

    // Sorted because [FlutterSecureStorage.readAll] promises no order, and
    // the one action this list exists to offer is FORGETTING a host's
    // pinned key. A list that reshuffles between visits is a list where the
    // row under the user's thumb is not the row they meant to tap, and the
    // cost of that mistake is trusting an unverified key on the next
    // connect. Same reason [_pinnedKeyTypes] sorts, with a sharper edge.
    //
    // Host, then port, then key type: a legacy pin carries no key type and
    // sorts before the current-scheme pins for the same host:port, which
    // puts the entry the user most likely wants to clear at the top of its
    // own group.
    pins.sort((a, b) {
      final byHost = a.host.compareTo(b.host);
      if (byHost != 0) return byHost;
      final byPort = a.port.compareTo(b.port);
      if (byPort != 0) return byPort;
      return (a.keyType ?? '').compareTo(b.keyType ?? '');
    });
    return pins;
  }

  /// Forgets the pinned key for this host, port and key type.
  ///
  /// The next connection is treated as a first contact. This is the escape
  /// hatch for a server that was legitimately rebuilt or re-keyed.
  ///
  /// Also clears any superseded entry for the same host and port. That
  /// entry is not key-type-scoped, so it cannot be attributed to a key type
  /// that survives — and leaving it would meet the user with a
  /// re-authorization prompt for the very host they just asked helm to
  /// forget.
  Future<void> removeHost({
    required String host,
    required int port,
    required String keyType,
  }) async {
    await _storage.delete(key: _storageKey(host, port, keyType));
    await _storage.delete(key: _legacyStorageKey(host, port));
    _log.i('Removed pinned host key for $host:$port ($keyType)');
  }

  // ── Private helpers ────────────────────────────────────────────────────

  /// Every current-scheme key type already pinned for [host]:[port],
  /// sorted, or an empty list when the host is unknown.
  ///
  /// Answers one question — "has this host been trusted under some other
  /// algorithm?" — which cannot be asked with a keyed read, because the
  /// key types are exactly what is unknown. [FlutterSecureStorage.readAll]
  /// is the only enumeration the plugin offers, and it is implemented on
  /// both targets helm ships: `FlutterSecureStorage.readAll()` in the
  /// Android plugin's Java, `readAll(params:)` in the Darwin plugin's
  /// Swift.
  ///
  /// It also decrypts every entry it returns, so its cost grows with the
  /// whole store. That is affordable only because of WHERE it is called:
  /// [verifyHostKey] reaches it solely on the path that would otherwise
  /// pin silently — no pin for this key type and no superseded entry — so
  /// it runs at most once per host and algorithm, and never on the
  /// connection path where a pin already matches.
  ///
  /// ### Why the prefix ends with the port AND a colon
  ///
  /// The match is `<prefix><host>:<port>:`, and every character of that
  /// tail is load-bearing. Storage keys are flat strings, so a prefix that
  /// stopped at the host would answer for the wrong machine: `mac` leads
  /// `mac.local`, and `10.0.0.1` leads `10.0.0.10` — the second being the
  /// realistic form on a LAN handing out consecutive addresses. Stopping
  /// after the port would move the same bug one segment along, where `2`
  /// leads `22`. Terminating on the colon that follows the port makes each
  /// segment match in full: `mac.local:22:` does not begin with `mac:22:`,
  /// and `10.0.0.10:22:` does not begin with `10.0.0.1:22:`, because the
  /// character facing the colon is a different one in each pair.
  ///
  /// Scanning under the CURRENT prefix also excludes superseded entries
  /// for free, and that direction is the only safe one:
  /// `helm_known_host_v2_` begins with `helm_known_host_`, so the two
  /// prefixes overlap by construction and a scan under the older one would
  /// sweep up current entries. Reading a legacy pin stays an exact keyed
  /// read for exactly that reason.
  ///
  /// A host whose NAME itself contains `<host>:<port>:` as a leading run —
  /// reachable only with IPv6-shaped literals such as `fe80` against a
  /// stored `fe80:1:2` — can still over-match. That direction is the safe
  /// one: over-matching raises a prompt where none was needed, while
  /// under-matching would restore the silent pin. The prefix is built from
  /// the same [host] and [port] being verified, so it cannot under-match.
  Future<List<String>> _pinnedKeyTypes({
    required String host,
    required int port,
  }) async {
    final prefix = '${AppConstants.knownHostV2StorageKeyPrefix}$host:$port:';

    // Deliberately unguarded. A failed enumeration is not evidence that the
    // host is unknown, so swallowing it and returning an empty list would
    // hand back the silent pin this method exists to remove — a store that
    // throws would become a store with nothing in it. Letting it propagate
    // fails the connection closed through `SSHService`'s verification
    // guard, which already logs and returns false for exactly this reason.
    // Reporting a placeholder key type instead would gate the connection
    // too, but only by inventing a fact for the prompt to show the user.
    final all = await _storage.readAll();

    final types = [
      for (final key in all.keys)
        if (key.startsWith(prefix)) key.substring(prefix.length),
    ]..sort();
    return types;
  }

  /// Trust identity is `host:port:keyType` — see
  /// [AppConstants.knownHostV2StorageKeyPrefix] for why each segment is
  /// there and why the three cannot collide.
  String _storageKey(String host, int port, String keyType) =>
      '${AppConstants.knownHostV2StorageKeyPrefix}$host:$port:$keyType';

  /// The superseded key shape, read-only. See
  /// [AppConstants.knownHostStorageKeyPrefix].
  String _legacyStorageKey(String host, int port) =>
      '${AppConstants.knownHostStorageKeyPrefix}$host:$port';
}
