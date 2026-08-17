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

      test('is not misreported as an authentication failure', () {
        expect(message, isNot('Authentication failed'));
      });
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
