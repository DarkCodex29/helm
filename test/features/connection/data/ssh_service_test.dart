import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';

/// Real `ssh-keygen -lf` output — see the fixture note in
/// `known_hosts_service_test.dart` for how it was produced and why it is a
/// captured value rather than a fabricated one.
const _realFingerprint = 'SHA256:uXVKYUuorbYlvO5eHey0nV9ncWa+6hojcBKZZ80PlzI';
const _otherFingerprint = 'SHA256:r8vvDRdBfIXWS7qkknHp7dTA1bYYd6aBBNmtNeI8Bag';

void main() {
  group('hostKeyVerificationCommand', () {
    test('points ed25519 at the ed25519 host key file', () {
      expect(
        hostKeyVerificationCommand('ssh-ed25519'),
        'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub',
      );
    });

    test('points every RSA variant at the one RSA host key file', () {
      // `ssh-rsa`, `rsa-sha2-256` and `rsa-sha2-512` are three SIGNATURE
      // algorithms over the same key. Sending the user to three different
      // files would send two of them to files that do not exist.
      for (final keyType in ['ssh-rsa', 'rsa-sha2-256', 'rsa-sha2-512']) {
        expect(
          hostKeyVerificationCommand(keyType),
          'ssh-keygen -lf /etc/ssh/ssh_host_rsa_key.pub',
          reason: keyType,
        );
      }
    });

    test('points every ECDSA curve at the one ECDSA host key file', () {
      for (final keyType in [
        'ecdsa-sha2-nistp256',
        'ecdsa-sha2-nistp384',
        'ecdsa-sha2-nistp521',
      ]) {
        expect(
          hostKeyVerificationCommand(keyType),
          'ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub',
          reason: keyType,
        );
      }
    });

    test('names exactly one file, because ssh-keygen -lf takes one', () {
      // Verified against OpenSSH: `ssh-keygen -lf a.pub b.pub` answers
      // "Too many arguments." A command with a glob or a second path would
      // fail in the user's hands.
      final command = hostKeyVerificationCommand('ssh-ed25519')!;

      expect(command.split(' ').where((w) => w.contains('/')).length, 1);
      expect(command, isNot(contains('*')));
    });

    test('returns null for a key type it does not know', () {
      // No guess. A fabricated path is worse than no instruction: it sends
      // the user to a file that does not exist and makes helm look wrong
      // about the thing it is asking them to trust.
      expect(hostKeyVerificationCommand('ssh-dss'), isNull);
      expect(hostKeyVerificationCommand(''), isNull);
    });
  });

  group('SSHService.describeError', () {
    test('reports authentication failures', () {
      final message = SSHService.describeError(
        SSHAuthFailError('no supported methods'),
      );

      expect(message, 'Authentication failed');
    });

    test('reports generic SSH errors with their detail', () {
      final message = SSHService.describeError(SSHStateError('bad packet'));

      expect(message, startsWith('SSH error:'));
      expect(message, contains('bad packet'));
    });

    test('falls back to toString for unknown errors', () {
      final message = SSHService.describeError(const FormatException('broken'));

      expect(message, contains('broken'));
    });

    group('host key mismatch', () {
      const error = HostKeyMismatchException(
        host: 'example.com',
        port: 2222,
        keyType: 'ssh-ed25519',
        expectedFingerprint: _realFingerprint,
        receivedFingerprint: _otherFingerprint,
      );

      final message = SSHService.describeError(error);

      test('names the man-in-the-middle risk', () {
        expect(message.toLowerCase(), contains('man-in-the-middle'));
      });

      test('identifies the host and port', () {
        expect(message, contains('example.com'));
        expect(message, contains('2222'));
      });

      test('shows both the expected and the received fingerprint', () {
        expect(message, contains(_realFingerprint));
        expect(message, contains(_otherFingerprint));
      });

      test('names the key algorithm the verdict is about', () {
        expect(message, contains('ssh-ed25519'));
      });

      test('tells the user how to recover from a legitimate rebuild', () {
        expect(message.toLowerCase(), contains('rebuilt'));
      });

      test('now sends the user to ssh-keygen to check the value', () {
        // The inverse of what this suite used to assert. While helm
        // double-hashed, these values could not match `ssh-keygen -lf` and
        // the copy correctly said so. They are now the same string OpenSSH
        // prints, so the honest instruction is the opposite one.
        expect(message, contains('ssh-keygen -lf'));
        expect(message, contains('/etc/ssh/ssh_host_ed25519_key.pub'));
      });

      test('no longer claims the value cannot match ssh-keygen', () {
        expect(message.toLowerCase(), isNot(contains('will not match')));
        expect(
          message.toLowerCase(),
          isNot(contains('not the fingerprint openssh publishes')),
        );
      });

      test('is not misreported as an authentication failure', () {
        expect(message, isNot('Authentication failed'));
      });

      test('is not misreported as a migration', () {
        expect(message.toLowerCase(), isNot(contains('changed how it')));
      });
    });

    group('host key migration', () {
      const error = HostKeyMigrationRequiredException(
        host: 'example.com',
        port: 2222,
        keyType: 'ssh-ed25519',
        receivedFingerprint: _realFingerprint,
        legacyFingerprint: _otherFingerprint,
      );

      final message = SSHService.describeError(error);

      test('does NOT raise the man-in-the-middle alarm', () {
        // The single most important assertion in this group. A migration
        // is not an attack, and reusing the interception copy would fire
        // helm's loudest warning at every already-pinned host on the first
        // launch after the upgrade — teaching the user to ignore it.
        expect(message.toLowerCase(), isNot(contains('man-in-the-middle')));
        expect(message.toLowerCase(), isNot(contains('impersonat')));
        expect(message.toLowerCase(), isNot(contains('attack')));
      });

      test('says helm changed, not that the key did', () {
        expect(message.toLowerCase(), contains('helm'));
        expect(message.toLowerCase(), contains('update'));
      });

      test('states plainly that this is not necessarily a key change', () {
        expect(message.toLowerCase(), contains('not necessarily'));
      });

      test('identifies the host and port being authorized', () {
        expect(message, contains('example.com'));
        expect(message, contains('2222'));
      });

      test('names the key algorithm', () {
        expect(message, contains('ssh-ed25519'));
      });

      test('shows the new fingerprint in OpenSSH form', () {
        expect(message, contains(_realFingerprint));
      });

      test('gives the exact command that verifies it', () {
        expect(
          message,
          contains('ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'),
        );
      });

      test('does not display the superseded value', () {
        // It is SHA256(MD5(host key)): a value the user cannot check
        // against anything. Showing it beside the new one invites exactly
        // the false comparison this change exists to stop.
        expect(message, isNot(contains(_otherFingerprint)));
      });

      test('explains why the old value is absent rather than hiding it', () {
        expect(message.toLowerCase(), contains('older format'));
        expect(message.toLowerCase(), contains('cannot be compared'));
      });

      test('is not misreported as an authentication failure', () {
        expect(message, isNot('Authentication failed'));
      });

      test('is not misreported as the generic SSH error', () {
        expect(message, isNot(startsWith('SSH error:')));
      });

      test('omits the command when the key type is unrecognised', () {
        const unknown = HostKeyMigrationRequiredException(
          host: 'example.com',
          port: 22,
          keyType: 'ssh-dss',
          receivedFingerprint: _realFingerprint,
          legacyFingerprint: _otherFingerprint,
        );

        final unknownMessage = SSHService.describeError(unknown);

        expect(unknownMessage, isNot(contains('ssh-keygen -lf')));
        expect(unknownMessage, contains(_realFingerprint));
      });
    });

    group('pty denial', () {
      final message = SSHService.describeError(
        SSHChannelRequestError('Failed to start pty'),
      );

      test('is not misreported as the generic SSH error', () {
        expect(message, isNot(startsWith('SSH error:')));
      });

      test('is not misreported as an authentication failure', () {
        expect(message, isNot('Authentication failed'));
      });

      test('names the pseudo-terminal denial', () {
        expect(message.toLowerCase(), contains('pseudo-terminal'));
      });

      test('points to a likely server-side restriction', () {
        expect(message.toLowerCase(), contains('restrict'));
      });

      test('is distinguished from other channel request failures by exact '
          'message, not just type', () {
        final otherChannelError = SSHService.describeError(
          SSHChannelRequestError('Failed to request agent forwarding'),
        );

        expect(otherChannelError, startsWith('SSH error:'));
        expect(
          otherChannelError.toLowerCase(),
          isNot(contains('pseudo-terminal')),
        );
      });
    });
  });

  group('HostKeyMismatchException', () {
    test('exposes the host, port, key type and both fingerprints', () {
      const error = HostKeyMismatchException(
        host: 'example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        expectedFingerprint: _realFingerprint,
        receivedFingerprint: _otherFingerprint,
      );

      expect(error.host, 'example.com');
      expect(error.port, 22);
      expect(error.keyType, 'ssh-ed25519');
      expect(error.expectedFingerprint, _realFingerprint);
      expect(error.receivedFingerprint, _otherFingerprint);
    });

    test('includes the fingerprints in toString for logs', () {
      const error = HostKeyMismatchException(
        host: 'example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        expectedFingerprint: _realFingerprint,
        receivedFingerprint: _otherFingerprint,
      );

      expect(error.toString(), contains(_realFingerprint));
      expect(error.toString(), contains(_otherFingerprint));
    });
  });

  group('HostKeyMigrationRequiredException', () {
    const error = HostKeyMigrationRequiredException(
      host: 'example.com',
      port: 22,
      keyType: 'ssh-ed25519',
      receivedFingerprint: _realFingerprint,
      legacyFingerprint: _otherFingerprint,
    );

    test('exposes what a re-authorization surface needs', () {
      expect(error.host, 'example.com');
      expect(error.port, 22);
      expect(error.keyType, 'ssh-ed25519');
      expect(error.receivedFingerprint, _realFingerprint);
      expect(error.legacyFingerprint, _otherFingerprint);
    });

    test('is not a HostKeyMismatchException', () {
      // Pinned deliberately. Any future refactor that makes a migration
      // catchable as a mismatch would silently restore the alarm this
      // change exists to separate it from.
      expect(error, isNot(isA<HostKeyMismatchException>()));
    });

    test('is an authorization gate', () {
      // What lets one notifier, one accept path and one overlay branch
      // serve both gates.
      expect(error, isA<HostKeyAuthorizationRequiredException>());
    });
  });

  group('HostKeyTypeAuthorizationRequiredException', () {
    const error = HostKeyTypeAuthorizationRequiredException(
      host: 'example.com',
      port: 22,
      keyType: 'ecdsa-sha2-nistp256',
      receivedFingerprint: _realFingerprint,
      knownKeyTypes: ['ssh-ed25519'],
    );

    test('exposes what an authorization surface needs', () {
      expect(error.host, 'example.com');
      expect(error.port, 22);
      expect(error.keyType, 'ecdsa-sha2-nistp256');
      expect(error.receivedFingerprint, _realFingerprint);
      expect(error.knownKeyTypes, ['ssh-ed25519']);
    });

    test('is an authorization gate', () {
      expect(error, isA<HostKeyAuthorizationRequiredException>());
    });

    test('is not a HostKeyMismatchException', () {
      // A newly offered key type contradicts no pinned fingerprint.
      // Letting it be caught as a mismatch would raise the interception
      // alarm for routine server maintenance.
      expect(error, isNot(isA<HostKeyMismatchException>()));
    });

    test('is not a HostKeyMigrationRequiredException', () {
      // Sibling, not variant. Catching one as the other would hand this
      // gate the migration's explanation, blaming a Helm upgrade for
      // something the server did.
      expect(error, isNot(isA<HostKeyMigrationRequiredException>()));
    });
  });

  group('SSHService.describeError for a new key type', () {
    const error = HostKeyTypeAuthorizationRequiredException(
      host: 'example.com',
      port: 2222,
      keyType: 'ecdsa-sha2-nistp256',
      receivedFingerprint: _realFingerprint,
      knownKeyTypes: ['ssh-ed25519'],
    );

    final message = SSHService.describeError(error);

    test('does NOT raise the man-in-the-middle alarm', () {
      // An added key type is usually a re-key or an administrator adding
      // a newer algorithm. Spending helm's loudest warning on that is how
      // the warning stops meaning anything.
      expect(message.toLowerCase(), isNot(contains('man-in-the-middle')));
      expect(message.toLowerCase(), isNot(contains('impersonat')));
      expect(message.toLowerCase(), isNot(contains('verification failed')));
    });

    test('does not borrow the migration explanation', () {
      // The other gate's cause. Repeating it here blames a Helm upgrade
      // for a change the server made.
      expect(message.toLowerCase(), isNot(contains('older format')));
      expect(message.toLowerCase(), isNot(contains('this update changed')));
    });

    test('names both the known key type and the new one', () {
      expect(message, contains('ssh-ed25519'));
      expect(message, contains('ecdsa-sha2-nistp256'));
    });

    test('says the host was already trusted', () {
      expect(message.toLowerCase(), contains('already trusted'));
    });

    test('identifies the host and port being authorized', () {
      expect(message, contains('example.com'));
      expect(message, contains('2222'));
    });

    test('shows the new fingerprint in OpenSSH form', () {
      expect(message, contains(_realFingerprint));
    });

    test('gives the command for the NEW key type, not the known one', () {
      // Pointing at the algorithm helm already trusts would send the user
      // to compare the wrong file, and the comparison would fail for a
      // reason that has nothing to do with the key being authorized.
      expect(
        message,
        contains('ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub'),
      );
      expect(
        message,
        isNot(contains('ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub')),
      );
    });

    test('says the existing keys are kept', () {
      // Removes the strongest reason to refuse a legitimate key.
      expect(message.toLowerCase(), contains('not replace'));
    });
  });
}
