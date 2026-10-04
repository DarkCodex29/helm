import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/session_hold/domain/auto_hold_request.dart';

void main() {
  late ValueNotifier<ConnectionStatus> status;

  setUp(() => status = ValueNotifier(ConnectionStatus.connected));
  tearDown(() => status.dispose());

  group('a profile that did not ask for a hold never gets one', () {
    test(
      'the request is null, so the connect path has nothing to hand the '
      'controller - the decision is taken here rather than by a controller '
      'that would otherwise be asked to hold and then refuse',
      () {
        final request = autoHoldRequest(
          profileHoldsInBackground: false,
          multiplexerSessionName: 'helm-deploy',
          profileName: 'Mac Studio',
          status: status,
        );

        expect(request, isNull);
      },
    );

    test(
      'a profile constructed with no opinion at all is treated as not '
      'asking - a foreground service is never inherited',
      () {
        expect(
          autoHoldRequest(
            profileHoldsInBackground: false,
            multiplexerSessionName: null,
            profileName: 'Contabo VPS',
            status: status,
          ),
          isNull,
        );
      },
    );
  });

  group('a profile that asked for a hold names the session it holds', () {
    test('a named multiplexer session is named, and its host beside it', () {
      final request = autoHoldRequest(
        profileHoldsInBackground: true,
        multiplexerSessionName: 'helm-deploy',
        profileName: 'Mac Studio',
        status: status,
      );

      // The same labelling rule the AppBar toggle already uses, and
      // deliberately not a second one: the notification must read the same
      // whether the hold was asked for by a tap or by this preference.
      expect(request, isNotNull);
      expect(request!.sessionName, 'helm-deploy');
      expect(request.hostName, 'Mac Studio');
    });

    test(
      'an unnamed session falls back to the profile name, exactly as a '
      'hand-tapped hold does',
      () {
        final request = autoHoldRequest(
          profileHoldsInBackground: true,
          multiplexerSessionName: null,
          profileName: 'Contabo VPS',
          status: status,
        );

        expect(request!.sessionName, 'Contabo VPS');
        expect(request.hostName, '');
      },
    );

    test(
      'the request carries the session\'s own status listenable, unchanged',
      () {
        final request = autoHoldRequest(
          profileHoldsInBackground: true,
          multiplexerSessionName: 'helm-deploy',
          profileName: 'Mac Studio',
          status: status,
        );

        // Identity, not equality. The controller keys "have I already got
        // this one?" and "did the user turn this one off?" on the identity
        // of this object, so a request that copied or wrapped it would
        // silently break both rules.
        expect(identical(request!.status, status), isTrue);
      },
    );
  });
}
