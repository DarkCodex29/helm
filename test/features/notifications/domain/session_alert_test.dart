import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/notifications/domain/session_alert.dart';

void main() {
  group('SessionAlert.fromData - the wire contract with the Mac', () {
    test('reads the session name, which is the only routing key', () {
      final alert = SessionAlert.fromData(const {
        'session': 'helm-a1b2c3d4',
        'pane_id': '%7',
        'agent': 'claude',
        'state': 'blocked',
      });

      expect(alert, isNotNull);
      expect(alert!.sessionName, 'helm-a1b2c3d4');
      expect(alert.paneId, '%7');
      expect(alert.agent, 'claude');
      expect(alert.state, 'blocked');
    });

    test('accepts a payload carrying nothing but the session name', () {
      // Every other key is display context. Requiring them would make the
      // notifier's four-key payload a coupling instead of a courtesy.
      final alert = SessionAlert.fromData(const {'session': 'work'});

      expect(alert, isNotNull);
      expect(alert!.sessionName, 'work');
      expect(alert.paneId, isNull);
      expect(alert.agent, isNull);
      expect(alert.state, isNull);
    });

    test('returns null when the session key is absent', () {
      expect(SessionAlert.fromData(const {'agent': 'claude'}), isNull);
    });

    test('returns null when the session key is empty or blank', () {
      expect(SessionAlert.fromData(const {'session': ''}), isNull);
      expect(SessionAlert.fromData(const {'session': '   '}), isNull);
    });

    test('returns null for an entirely empty payload', () {
      expect(SessionAlert.fromData(const {}), isNull);
    });

    test('returns null when session is present but not a string', () {
      // FCM data values are strings on the wire, but the Dart map is typed
      // `Map<String, dynamic>` and a background isolate can be handed a
      // decoded map from anywhere.
      expect(SessionAlert.fromData(const {'session': 42}), isNull);
      expect(SessionAlert.fromData(const {'session': null}), isNull);
    });

    test('ignores non-string context values instead of failing on them', () {
      final alert = SessionAlert.fromData(const {
        'session': 'work',
        'pane_id': 7,
        'agent': ['nope'],
      });

      expect(alert, isNotNull);
      expect(alert!.paneId, isNull);
      expect(alert.agent, isNull);
    });
  });

  group('SessionAlert.fromData - the display context the notifier sends', () {
    test('reads place, area and doing alongside the routing key', () {
      final alert = SessionAlert.fromData(const {
        'session': 'helm-a1b2c3d4',
        'place': 'Go Nexa',
        'area': 'Helm',
        'doing': 'OC | Sincronizar archivos Mac a movil',
      });

      expect(alert, isNotNull);
      expect(alert!.place, 'Go Nexa');
      expect(alert.area, 'Helm');
      expect(alert.doing, 'OC | Sincronizar archivos Mac a movil');
    });

    test('treats a blank context value as absent, because FCM cannot say so',
        () {
      // FCM's data map is map<string,string> on the wire. The sender has
      // no way to express "I do not know the workspace" other than by
      // sending an empty string, so an empty string has to mean it — the
      // alternative is a header line that renders as a bare separator.
      final alert = SessionAlert.fromData(const {
        'session': 'work',
        'place': '',
        'area': '   ',
        'doing': '',
        'pane_id': '',
        'agent': '  ',
      });

      expect(alert, isNotNull);
      expect(alert!.place, isNull);
      expect(alert.area, isNull);
      expect(alert.doing, isNull);
      expect(alert.paneId, isNull, reason: 'same wire contract, same rule');
      expect(alert.agent, isNull);
    });

    test('a payload carrying no context at all still yields an alert', () {
      final alert = SessionAlert.fromData(const {'session': 'work'});

      expect(alert, isNotNull);
      expect(alert!.place, isNull);
      expect(alert.area, isNull);
      expect(alert.doing, isNull);
    });

    test('ignores a non-string context value instead of failing on it', () {
      final alert = SessionAlert.fromData(const {
        'session': 'work',
        'place': 7,
        'area': ['nope'],
        'doing': null,
      });

      expect(alert, isNotNull);
      expect(alert!.place, isNull);
      expect(alert.area, isNull);
      expect(alert.doing, isNull);
    });
  });

  group('SessionAlert payload round-trip', () {
    // flutter_local_notifications carries a single `String? payload`, while
    // FCM carries a map. JSON is the bridge between the two.
    test('survives a round-trip through its string payload', () {
      const original = SessionAlert(
        sessionName: 'helm-a1b2c3d4',
        paneId: '%7',
        agent: 'claude',
        state: 'blocked',
      );

      final restored = SessionAlert.fromPayload(original.toPayload());

      expect(restored, isNotNull);
      expect(restored!.sessionName, original.sessionName);
      expect(restored.paneId, original.paneId);
      expect(restored.agent, original.agent);
      expect(restored.state, original.state);
    });

    test('carries the display context through the round-trip as well', () {
      // A tap needs only the session name, so context is not required for
      // routing. It travels anyway: a round-trip that silently drops
      // fields is a trap for whoever next reaches for one of them.
      const original = SessionAlert(
        sessionName: 'helm-a1b2c3d4',
        place: 'Go Nexa',
        area: 'Helm',
        doing: 'OC | Sincronizar archivos',
      );

      final restored = SessionAlert.fromPayload(original.toPayload());

      expect(restored!.place, 'Go Nexa');
      expect(restored.area, 'Helm');
      expect(restored.doing, 'OC | Sincronizar archivos');
    });

    test('omits absent context rather than writing nulls into the payload',
        () {
      const original = SessionAlert(sessionName: 'work');

      final payload = original.toPayload();

      expect(payload, isNot(contains('place')));
      expect(payload, isNot(contains('area')));
      expect(payload, isNot(contains('doing')));
      expect(payload, isNot(contains('null')));
    });

    test('degrades to null for a payload that is not JSON', () {
      expect(SessionAlert.fromPayload('not json at all'), isNull);
    });

    test('degrades to null for JSON that is not an object', () {
      expect(SessionAlert.fromPayload('["session"]'), isNull);
      expect(SessionAlert.fromPayload('"work"'), isNull);
    });

    test('degrades to null for a null or empty payload', () {
      expect(SessionAlert.fromPayload(null), isNull);
      expect(SessionAlert.fromPayload(''), isNull);
    });
  });

  group('SessionAlert.routeLocation', () {
    test('addresses the session route', () {
      const alert = SessionAlert(sessionName: 'helm-a1b2c3d4');

      expect(alert.routeLocation, '/session/helm-a1b2c3d4');
    });

    test('encodes a name that would otherwise change the path shape', () {
      // A session name is a remote string this app does not control. An
      // unencoded `/` in it would silently address a different route.
      const alert = SessionAlert(sessionName: 'team/build');

      expect(alert.routeLocation, '/session/team%2Fbuild');
      expect(Uri.parse(alert.routeLocation).pathSegments.length, 2);
    });

    test('a name round-trips through the route it produces', () {
      const alert = SessionAlert(sessionName: 'my session #1');

      final decoded = Uri.decodeComponent(
        Uri.parse(alert.routeLocation).pathSegments.last,
      );

      expect(decoded, 'my session #1');
    });
  });
}
