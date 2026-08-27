// How a TerminalSession surfaces the one-time host key re-authorization
// introduced when Helm stopped double-hashing dartssh2's fingerprint.
//
// The decision cannot be taken inside dartssh2's `onVerifyHostKey`: that
// callback runs mid-handshake with the server waiting on NEWKEYS, so
// parking it on a human would burn OpenSSH's LoginGraceTime and fail the
// connection anyway. The connection therefore fails CLOSED first, and the
// question reaches the user afterwards — which is what these tests pin.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';

import '../../../helpers/fake_ssh_service.dart';

/// The channel `flutter_secure_storage` invokes. `TerminalSession.reconnect`
/// builds its own unconfigurable `SSHKeyService()`, so reaching the dial at
/// the end of `trustHostKeyAndReconnect` means answering this directly —
/// the same seam `terminal_session_test.dart` documents for `reconnect`.
const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

const _profile = ConnectionProfile(
  id: 'profile-1',
  name: 'Test Host',
  host: 'example.test',
  port: 2222,
  username: 'tester',
);

const _fingerprint = 'SHA256:uXVKYUuorbYlvO5eHey0nV9ncWa+6hojcBKZZ80PlzI';
const _legacy = 'SHA256:r8vvDRdBfIXWS7qkknHp7dTA1bYYd6aBBNmtNeI8Bag';

const _migration = HostKeyMigrationRequiredException(
  host: 'example.test',
  port: 2222,
  keyType: 'ssh-ed25519',
  receivedFingerprint: _fingerprint,
  legacyFingerprint: _legacy,
);

const _newKeyType = HostKeyTypeAuthorizationRequiredException(
  host: 'example.test',
  port: 2222,
  keyType: 'ecdsa-sha2-nistp256',
  receivedFingerprint: _fingerprint,
  knownKeyTypes: ['ssh-ed25519'],
);

const _mismatch = HostKeyMismatchException(
  host: 'example.test',
  port: 2222,
  keyType: 'ssh-ed25519',
  expectedFingerprint: _legacy,
  receivedFingerprint: _fingerprint,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSSHService ssh;
  late TerminalSession session;

  setUp(() {
    ssh = FakeSSHService();
    session = TerminalSession(profile: _profile, sshService: ssh);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _secureStorageChannel,
          (call) async => call.method == 'read' ? 'stored-pem-key' : null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorageChannel, null);
  });

  Future<void> failConnectWith(Object error) async {
    ssh.queueConnectError(error);
    await expectLater(session.connect('pem'), throwsA(same(error)));
  }

  group('pendingHostKeyMigration', () {
    test('is null on a session that has not connected', () {
      expect(session.hostKeyAuthorizationNotifier.value, isNull);
    });

    test('is published when a connection needs re-authorization', () async {
      await failConnectWith(_migration);

      expect(session.hostKeyAuthorizationNotifier.value, same(_migration));
    });

    test('is NOT published for a genuine mismatch', () async {
      await failConnectWith(_mismatch);

      // The alarm and the migration are different surfaces on purpose. A
      // mismatch reaching the re-authorization prompt would offer the user
      // a one-tap "trust" button for what may be an interception.
      expect(session.hostKeyAuthorizationNotifier.value, isNull);
    });

    test('is NOT published for an ordinary connection failure', () async {
      await failConnectWith(const FormatException('broken'));

      expect(session.hostKeyAuthorizationNotifier.value, isNull);
    });

    test('is cleared when a new attempt begins', () async {
      await failConnectWith(_migration);
      expect(session.hostKeyAuthorizationNotifier.value, isNotNull);

      await failConnectWith(const FormatException('broken'));

      // A prompt describing the previous attempt must not sit next to a
      // fresh, unrelated failure.
      expect(session.hostKeyAuthorizationNotifier.value, isNull);
    });

    test('is published for a key type this host has not shown', () async {
      // The second gate rides the same notifier. Without this, an
      // unpinned key type would fail the connection with terminal copy
      // only — text the multiplexer clears on attach, carrying a
      // fingerprint the user cannot select or copy.
      await failConnectWith(_newKeyType);

      expect(session.hostKeyAuthorizationNotifier.value, same(_newKeyType));
    });

    test('routes a new key type to its own acceptance', () async {
      // The two gates differ in what they touch besides the new pin: a
      // migration deletes the superseded entry, a new key type must leave
      // every existing pin standing. Servicing both with one write would
      // either strand a legacy record or discard trust never withdrawn.
      await failConnectWith(_newKeyType);

      await session.trustHostKeyAndReconnect();

      expect(ssh.acceptedAuthorizations, [same(_newKeyType)]);
    });
  });

  group('trustHostKeyAndReconnect', () {
    test('does nothing when no re-authorization is pending', () async {
      await session.trustHostKeyAndReconnect();

      expect(ssh.acceptedAuthorizations, isEmpty);
      expect(ssh.connectCalls, isEmpty);
    });

    test('records the trust decision for the pending host', () async {
      await failConnectWith(_migration);
      ssh.queueConnectError(const FormatException('still down'));

      await session.trustHostKeyAndReconnect();

      expect(ssh.acceptedAuthorizations, [same(_migration)]);
    });

    test('trusts before dialling, never after', () async {
      await failConnectWith(_migration);
      ssh.queueConnectError(const FormatException('still down'));
      // Forget the arranged failure's own dial, so what is asserted below
      // is the order of THIS operation rather than of the whole fixture.
      ssh.orderOfCalls.clear();

      await session.trustHostKeyAndReconnect();

      // Reconnecting first would fail on the very pin this is meant to
      // replace, and the retry would be spent proving what is already
      // known. Asserted as an exact sequence: both orders leave the same
      // call counts behind, so only the order distinguishes them.
      expect(ssh.orderOfCalls, ['acceptAuthorization', 'connectAndOpenShell']);
    });

    test('reconnects once the key is trusted', () async {
      await failConnectWith(_migration);
      ssh.queueConnectError(const FormatException('still down'));
      final dialsBefore = ssh.connectCalls.length;

      await session.trustHostKeyAndReconnect();

      expect(ssh.connectCalls.length - dialsBefore, 1);
    });

    test('clears the prompt so it cannot be answered twice', () async {
      await failConnectWith(_migration);
      ssh.queueConnectError(const FormatException('still down'));

      await session.trustHostKeyAndReconnect();

      expect(session.hostKeyAuthorizationNotifier.value, isNull);
    });

    test('does not re-trust when invoked again after answering', () async {
      await failConnectWith(_migration);
      ssh.queueConnectError(const FormatException('still down'));
      await session.trustHostKeyAndReconnect();

      await session.trustHostKeyAndReconnect();

      expect(ssh.acceptedAuthorizations, hasLength(1));
    });

    test('leaves the store untouched if the user never answers', () async {
      await failConnectWith(_migration);

      expect(ssh.acceptedAuthorizations, isEmpty);
      expect(session.status, ConnectionStatus.error);
    });
  });

  group('dispose', () {
    test('releases the prompt notifier', () async {
      await failConnectWith(_migration);

      await session.dispose();

      // Disposing a ValueNotifier twice throws, so this both proves the
      // notifier was disposed and pins that it happens exactly once.
      expect(session.hostKeyAuthorizationNotifier.dispose, throwsFlutterError);
    });
  });
}
