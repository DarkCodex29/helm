import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/session_hold/domain/hold_labels.dart';

void main() {
  final status = ValueNotifier(ConnectionStatus.connected);

  group('holdableSession', () {
    test('names the multiplexer session when there is one', () {
      final held = holdableSession(
        multiplexerSessionName: 'helm-a1b2c3d4',
        profileName: 'Mac Studio',
        status: status,
      );

      expect(held.sessionName, 'helm-a1b2c3d4');
      expect(held.hostName, 'Mac Studio');
    });

    test('falls back to the profile for a session with no name', () {
      // A plain shell with no multiplexer. Refusing to hold it would deny
      // the feature to the case that needs it MOST: a multiplexer session
      // survives on the host and costs only a reconnect, while a plain
      // shell is gone for good when the process dies.
      final held = holdableSession(
        multiplexerSessionName: null,
        profileName: 'Mac Studio',
        status: status,
      );

      expect(held.sessionName, 'Mac Studio');
      // Blanked so the notification does not read
      // "Holding Mac Studio — connected on Mac Studio".
      expect(held.hostName, isEmpty);
    });

    test('a whitespace-only name is not a name', () {
      final held = holdableSession(
        multiplexerSessionName: '   ',
        profileName: 'Mac Studio',
        status: status,
      );

      expect(held.sessionName, 'Mac Studio');
      expect(held.hostName, isEmpty);
    });

    test('a padded name is trimmed rather than rejected', () {
      final held = holdableSession(
        multiplexerSessionName: '  helm-deploy  ',
        profileName: 'Mac Studio',
        status: status,
      );

      expect(held.sessionName, 'helm-deploy');
      expect(held.hostName, 'Mac Studio');
    });

    test('carries the session status through unchanged', () {
      final held = holdableSession(
        multiplexerSessionName: 'helm-x',
        profileName: 'Mac Studio',
        status: status,
      );

      // Identity, not equality: the controller keys "am I already holding
      // this?" on it.
      expect(identical(held.status, status), isTrue);
    });
  });
}
