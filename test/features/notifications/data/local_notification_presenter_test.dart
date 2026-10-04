import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/features/notifications/data/local_notification_presenter.dart';
import 'package:helm/features/terminal/presentation/widgets/agent_state_chip.dart';

/// The id `SessionHoldService.kt` posts its foreground notification on.
///
/// Duplicated here rather than imported because it lives in Kotlin. The
/// point of the test that uses it is precisely that the two numbers are
/// decided in different languages and must still not meet.
const int _sessionHoldNotificationId = 42;

void main() {
  group('notificationIdForKey — one slot per thing, not one for all', () {
    test('two different keys land on two different ids', () {
      // The whole bug this replaces: a single constant id meant the second
      // agent to speak silently erased the first, which reads as grouping
      // and is data loss.
      expect(notificationIdForKey('%7'), isNot(notificationIdForKey('%9')));
    });

    test('the same key lands on the same id, so a repeat replaces', () {
      expect(notificationIdForKey('%7'), notificationIdForKey('%7'));
    });

    test('a null key collapses every unkeyed alert onto one shared slot', () {
      // Honest rather than convenient: nothing distinguishes two alerts
      // the sender could not name, so nothing should pretend to.
      expect(notificationIdForKey(null), notificationIdForKey(null));
      expect(notificationIdForKey(null), isNot(notificationIdForKey('%7')));
    });

    test('never collides with the hold notification the service owns', () {
      // SessionHoldService must keep its notification for as long as it
      // runs; an alert that overwrote it would leave a foreground service
      // with no visible notification, which the platform forbids.
      final ids = [
        for (var i = 0; i < 2000; i++) notificationIdForKey('%$i'),
        notificationIdForKey(null),
      ];

      expect(ids, isNot(contains(_sessionHoldNotificationId)));
    });

    test('stays inside a positive 32-bit signed int, as Android requires', () {
      // Android notification ids are Java ints. A negative or overflowing
      // value is not rejected loudly — it is accepted and then behaves
      // unpredictably across the platform-channel boundary.
      for (final key in ['%7', 'helm-a1b2c3d4', 'a' * 512, '', '💥']) {
        final id = notificationIdForKey(key);
        expect(id, greaterThan(0));
        expect(id, lessThan(0x7FFFFFFF));
      }
    });

    test('is derived from the key, not from Dart String.hashCode', () {
      // String.hashCode is documented as unstable across Dart releases.
      // A notification drawn before an app update would stop being
      // replaceable after it, so the mapping is computed here instead.
      //
      // These goldens were produced by an independent FNV-1a
      // implementation in Python, not by reading this app's output back.
      expect(notificationIdForKey('%7'), 26685);
      expect(notificationIdForKey('%9'), 81923);
      expect(notificationIdForKey('helm-a1b2c3d4'), 48852);
    });

    test('spreads a realistic set of panes without collisions', () {
      final ids = [
        '%0',
        '%1',
        '%7',
        '%9',
        '%13',
        '%42',
      ].map(notificationIdForKey).toSet();

      expect(ids, hasLength(6));
    });
  });

  group('both delivery paths draw the same notification', () {
    // helm draws the foreground case from Dart; the Firebase SDK draws the
    // backgrounded and killed cases from its own service, with no Dart
    // running, reading the manifest instead. The two cannot import each
    // other, so the only thing stopping one feature from having two
    // appearances is that these values are checked against each other.
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final colors = File(
      'android/app/src/main/res/values/colors.xml',
    ).readAsStringSync();

    /// The `#AARRGGBB` literal declared for [name] in `colors.xml`.
    String colorLiteral(String name) {
      final match = RegExp(
        '<color name="$name">(#[0-9A-Fa-f]{8})</color>',
      ).firstMatch(colors);
      expect(match, isNotNull, reason: 'no <color name="$name"> in colors.xml');
      return match!.group(1)!.toUpperCase();
    }

    /// The resource `meta-data` named [name] points at.
    String metaDataResource(String name) {
      final match = RegExp(
        'android:name="$name"\\s+android:resource="([^"]+)"',
      ).firstMatch(manifest);
      expect(match, isNotNull, reason: 'no <meta-data> named $name');
      return match!.group(1)!;
    }

    test('the alert accent is the amber the app reserves for "needs you"', () {
      // Not a second brand colour. `agent_state_chip.dart` is where the
      // decision was argued; this asserts the notification did not quietly
      // pick its own.
      expect(
        kAgentAlertAccentColor,
        AgentStateStyle.of(AgentState.blocked).color,
      );
    });

    test('colors.xml carries the same amber the Dart constant does', () {
      final dartHex =
          '#${kAgentAlertAccentColor.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

      expect(colorLiteral('helm_notification_accent'), dartHex);
    });

    test('the hold accent is the blue reserved for "working"', () {
      // Deliberately NOT the alert amber: a hold never needs a response,
      // and spending the urgent colour on it would devalue it everywhere
      // that does.
      final holdHex = colorLiteral('helm_hold_accent');
      final workingHex =
          '#${AgentStateStyle.of(AgentState.working).color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

      expect(holdHex, workingHex);
      expect(holdHex, isNot(colorLiteral('helm_notification_accent')));
    });

    test('the manifest points Firebase at the icon Dart also names', () {
      expect(
        metaDataResource(
          'com.google.firebase.messaging.default_notification_icon',
        ),
        '@drawable/$kAgentAlertIconResource',
      );
    });

    test('the manifest points Firebase at the colour Dart also uses', () {
      expect(
        metaDataResource(
          'com.google.firebase.messaging.default_notification_color',
        ),
        '@color/helm_notification_accent',
      );
    });

    test('the icon drawable the manifest names actually exists', () {
      expect(
        File(
          'android/app/src/main/res/drawable/$kAgentAlertIconResource.xml',
        ).existsSync(),
        isTrue,
      );
    });

    test('the icon is drawn white on transparent, never filled', () {
      // Android keeps only the ALPHA channel of a small icon and refills
      // it. An opaque fill would silhouette as the icon's own bounding
      // box — which is exactly how the launcher icon produced a white
      // square, the symptom this replaced.
      final icon = File(
        'android/app/src/main/res/drawable/$kAgentAlertIconResource.xml',
      ).readAsStringSync();

      final fills = RegExp(
        'android:fillColor="([^"]+)"',
      ).allMatches(icon).map((m) => m.group(1)!.toUpperCase());
      final strokes = RegExp(
        'android:strokeColor="([^"]+)"',
      ).allMatches(icon).map((m) => m.group(1)!.toUpperCase());

      expect(fills, isNotEmpty);
      expect(fills, everyElement('#00000000'), reason: 'fills must be clear');
      expect(strokes, isNotEmpty);
      expect(
        strokes,
        everyElement('#FFFFFFFF'),
        reason: 'strokes must be white',
      );
    });

    test('the alert channel id is the one the manifest hands Firebase', () {
      // Pre-existing contract, re-asserted here because this group is now
      // the one place that checks the Dart/manifest pair at all.
      expect(manifest, contains('android:value="$kAgentAlertChannelId"'));
    });
  });

  group('iOS initialization asks for no permission at launch', () {
    // What this CAN prove: the shape of the object this code hands the
    // plugin. `_plugin.initialize(...)` crosses a platform channel, and
    // nothing running under `flutter_test` can observe what iOS does with
    // it — these assertions stop at the Dart side of that boundary.
    //
    // What it proves anyway: the one thing a future edit is most likely to
    // undo by accident. `DarwinInitializationSettings` defaults all three
    // request* flags to true, and accepting that default would ask for
    // notification permission at app launch — exactly the launch-time ask
    // `PushNotificationService.onAgentTrackingStarted`'s doc comment argues
    // against, on a supply of prompts it calls "small and non-renewable".
    test('iOS settings are present, so initialize does not throw', () {
      expect(kAgentAlertInitializationSettings.iOS, isNotNull);
    });

    test(
      'no permission is requested — the ask stays at onAgentTrackingStarted',
      () {
        final ios = kAgentAlertInitializationSettings.iOS!;
        expect(ios.requestAlertPermission, isFalse);
        expect(ios.requestSoundPermission, isFalse);
        expect(ios.requestBadgePermission, isFalse);
      },
    );

    test('Android settings are unchanged by the iOS addition', () {
      expect(
        kAgentAlertInitializationSettings.android?.defaultIcon,
        '@drawable/$kAgentAlertIconResource',
      );
    });
  });
}
