import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/data/known_hosts_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';

void main() {
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
        expectedFingerprint: 'SHA256:expected-value',
        receivedFingerprint: 'SHA256:received-value',
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
        expect(message, contains('SHA256:expected-value'));
        expect(message, contains('SHA256:received-value'));
      });

      test('tells the user how to recover from a legitimate rebuild', () {
        expect(message.toLowerCase(), contains('rebuilt'));
      });

      // The displayed value is SHA256(MD5(host key)): dartssh2 2.16.0
      // hands onVerifyHostKey an MD5 digest rather than the raw key (see
      // ssh_service.dart's callback comment), and KnownHostsService then
      // SHA-256s that digest. It therefore cannot equal what
      // `ssh-keygen -lf` prints, whatever the SHA256: prefix suggests.
      //
      // Changing the algorithm is a trust-store migration and belongs to
      // its own change. What must not survive until then is copy that
      // sends the user to run a comparison that can never match.
      test(
        'does not instruct the user to compare this value on the server',
        () {
          expect(
            message.toLowerCase(),
            isNot(contains('confirm the new fingerprint directly on the '
                'server')),
          );
        },
      );

      test('discloses that these are not ssh-keygen fingerprints', () {
        expect(message, contains('ssh-keygen'));
        expect(message.toLowerCase(), contains('will not match'));
      });

      test('still offers a verification route the user can actually take', () {
        expect(message.toLowerCase(), contains('trust'));
      });

      test('is not misreported as an authentication failure', () {
        expect(message, isNot('Authentication failed'));
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

      test(
        'is distinguished from other channel request failures by exact '
        'message, not just type',
        () {
          final otherChannelError = SSHService.describeError(
            SSHChannelRequestError('Failed to request agent forwarding'),
          );

          expect(otherChannelError, startsWith('SSH error:'));
          expect(
            otherChannelError.toLowerCase(),
            isNot(contains('pseudo-terminal')),
          );
        },
      );
    });
  });

  group('HostKeyMismatchException', () {
    test('exposes the host, port and both fingerprints', () {
      const error = HostKeyMismatchException(
        host: 'example.com',
        port: 22,
        expectedFingerprint: 'SHA256:aaa',
        receivedFingerprint: 'SHA256:bbb',
      );

      expect(error.host, 'example.com');
      expect(error.port, 22);
      expect(error.expectedFingerprint, 'SHA256:aaa');
      expect(error.receivedFingerprint, 'SHA256:bbb');
    });

    test('includes the fingerprints in toString for logs', () {
      const error = HostKeyMismatchException(
        host: 'example.com',
        port: 22,
        expectedFingerprint: 'SHA256:aaa',
        receivedFingerprint: 'SHA256:bbb',
      );

      expect(error.toString(), contains('SHA256:aaa'));
      expect(error.toString(), contains('SHA256:bbb'));
    });
  });
}
