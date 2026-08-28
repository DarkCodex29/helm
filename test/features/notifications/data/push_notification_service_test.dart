import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/features/notifications/data/push_messaging_gateway.dart';
import 'package:helm/features/notifications/data/push_notification_service.dart';
import 'package:helm/features/notifications/domain/session_alert.dart';

import '../../../helpers/fake_local_notification_presenter.dart';
import '../../../helpers/fake_push_messaging_gateway.dart';

/// Records the scripts it is asked to run and always succeeds.
class _Runner implements HostCommandRunner {
  final List<String> scripts = [];

  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) async =>
      const HostCommandResult(exitCode: 0);

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) async {
    scripts.add(script);
    return const HostCommandResult(exitCode: 0);
  }
}

/// A runner whose every call throws, modelling a transport that died.
class _BrokenRunner implements HostCommandRunner {
  @override
  Future<HostCommandResult> run(String command, {Duration? timeout}) =>
      throw StateError('transport gone');

  @override
  Future<HostCommandResult> runScript(String script, {Duration? timeout}) =>
      throw StateError('transport gone');
}

/// A gateway whose [initialize] never completes, modelling a platform
/// channel that has gone away.
class _WedgedGateway extends FakePushMessagingGateway {
  @override
  Future<void> initialize() => Completer<void>().future;
}

void main() {
  late FakePushMessagingGateway gateway;
  late FakeLocalNotificationPresenter presenter;
  late List<SessionAlert> opened;
  late PushNotificationService service;

  setUp(() {
    gateway = FakePushMessagingGateway();
    presenter = FakeLocalNotificationPresenter();
    opened = [];
    service = PushNotificationService(
      gateway: gateway,
      presenter: presenter,
      onAlertOpened: opened.add,
    );
  });

  tearDown(() async {
    await service.dispose();
    await gateway.close();
  });

  PushMessage alertMessage({
    String session = 'helm-a1b2c3d4',
    String title = 'claude needs you',
    String body = 'helm-a1b2c3d4 - %7 - blocked',
  }) => PushMessage(
    data: {
      'session': session,
      'pane_id': '%7',
      'agent': 'claude',
      'state': 'blocked',
    },
    title: title,
    body: body,
  );

  group('cold start reads the launch payload rather than awaiting a tap', () {
    test('resolves the alert the notification launched the app with', () async {
      gateway.launch = alertMessage();

      final alert = await service.resolveLaunchAlert();

      expect(alert, isNotNull);
      expect(alert!.sessionName, 'helm-a1b2c3d4');
      expect(gateway.launchMessageCalls, 1);
    });

    test('reads it without needing the tap stream to have fired', () async {
      // The entire point of getInitialMessage/getNotificationAppLaunchDetails:
      // on a cold start the tap already happened, before any Dart existed to
      // observe it, so onMessageOpenedApp never fires for it. A design that
      // waited for the callback would hang forever on exactly the launch the
      // user cared most about.
      gateway.launch = alertMessage();

      final alert = await service.resolveLaunchAlert();

      expect(alert, isNotNull);
      expect(opened, isEmpty, reason: 'no stream event was required');
    });

    test('falls back to the local plugin when FCM reports no launch message',
        () async {
      // A notification helm drew itself, while in the foreground, that the
      // user then backgrounded the app and tapped. FCM knows nothing about
      // it; only flutter_local_notifications does.
      gateway.launch = null;
      presenter.launchPayloadValue =
          const SessionAlert(sessionName: 'from-local').toPayload();

      final alert = await service.resolveLaunchAlert();

      expect(alert?.sessionName, 'from-local');
    });

    test('prefers the FCM launch message over the local one', () async {
      gateway.launch = alertMessage(session: 'from-fcm');
      presenter.launchPayloadValue =
          const SessionAlert(sessionName: 'from-local').toPayload();

      final alert = await service.resolveLaunchAlert();

      expect(alert?.sessionName, 'from-fcm');
    });

    test('returns null when nothing launched the app', () async {
      expect(await service.resolveLaunchAlert(), isNull);
    });
  });

  group('a malformed payload degrades instead of crashing', () {
    test('a launch message with no session resolves to null', () async {
      gateway.launch = const PushMessage(data: {'agent': 'claude'});

      expect(await service.resolveLaunchAlert(), isNull);
    });

    test('a launch payload that is not JSON resolves to null', () async {
      presenter.launchPayloadValue = 'not json';

      expect(await service.resolveLaunchAlert(), isNull);
    });

    test('a launch message whose data is empty resolves to null', () async {
      gateway.launch = const PushMessage(data: {});

      expect(await service.resolveLaunchAlert(), isNull);
    });

    test('a gateway that throws still yields null rather than propagating',
        () async {
      // Firebase can fail at launch on a device with no Play Services.
      // Taking the whole app down before the router is built would turn a
      // missing notification into a phone that cannot open helm at all.
      gateway.initializeError = StateError('no play services');
      gateway.launch = alertMessage();

      expect(await service.resolveLaunchAlert(), isNull);
    });

    test('a start() on a device where Firebase cannot start still completes',
        () async {
      gateway.initializeError = StateError('no play services');

      await expectLater(service.start(), completes);
    });

    test('a platform channel that never answers does not block the launch',
        () async {
      // resolveLaunchAlert is awaited BEFORE runApp. An unbounded wait on
      // a wedged channel is not a missed deep link, it is a white screen
      // for as long as the user is willing to stare at one.
      final wedged = _WedgedGateway();
      final bounded = PushNotificationService(
        gateway: wedged,
        presenter: presenter,
        onAlertOpened: opened.add,
        launchTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(bounded.dispose);

      final stopwatch = Stopwatch()..start();
      final alert = await bounded.resolveLaunchAlert();
      stopwatch.stop();

      expect(alert, isNull);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a tap carrying no session opens nothing', () async {
      await service.start();

      gateway.emitTap(const PushMessage(data: {'state': 'idle'}));
      await pumpEventQueue();

      expect(opened, isEmpty);
    });
  });

  group('permission is asked when it has earned a purpose', () {
    test('start() does NOT ask, so launch spends no dialog', () async {
      // Android grants exactly one POST_NOTIFICATIONS dialog per install.
      // Asking before the user has connected anything is how that single
      // dialog gets spent on a "no" that cannot be re-prompted.
      await service.start();

      expect(gateway.requestPermissionCalls, 0);
    });

    test('asks the first time agent tracking actually turns on', () async {
      await service.start();

      await service.onAgentTrackingStarted(_Runner());

      expect(gateway.requestPermissionCalls, 1);
    });

    test('asks once, however many sessions attach afterwards', () async {
      await service.start();

      await service.onAgentTrackingStarted(_Runner());
      await service.onAgentTrackingStarted(_Runner());
      await service.onAgentTrackingStarted(_Runner());

      expect(gateway.requestPermissionCalls, 1);
    });
  });

  group('the token reaches the Mac over the connection already open', () {
    test('registers on the first attach', () async {
      final runner = _Runner();
      await service.start();

      await service.onAgentTrackingStarted(runner);

      expect(runner.scripts, hasLength(1));
      expect(runner.scripts.single, contains('fake-token'));
      expect(runner.scripts.single, contains('device-tokens.json'));
    });

    test('registers again on reconnect, because the file may be gone',
        () async {
      await service.start();
      final first = _Runner();
      final second = _Runner();

      await service.onAgentTrackingStarted(first);
      await service.onAgentTrackingStarted(second);

      expect(first.scripts, hasLength(1));
      expect(second.scripts, hasLength(1));
    });

    test('re-registers when FCM mints a new token', () async {
      final runner = _Runner();
      await service.start();
      await service.onAgentTrackingStarted(runner);

      gateway.emitTokenRefresh('token-after-reinstall');
      await pumpEventQueue();

      expect(runner.scripts, hasLength(2));
      expect(runner.scripts.last, contains('token-after-reinstall'));
    });

    test('a refresh before any connection registers nothing, and does not throw',
        () async {
      await service.start();

      gateway.emitTokenRefresh('token-with-no-host');
      await pumpEventQueue();

      // Nothing to assert but the absence of a crash: there is no runner
      // to send it over, and the next attach re-reads the current token.
      expect(opened, isEmpty);
    });

    test('registers even when the user denied the permission', () async {
      // The token stays valid, and a user who later enables notifications
      // in system settings should not have to reconnect to be reachable.
      gateway.permission = PushPermission.denied;
      final runner = _Runner();
      await service.start();

      await service.onAgentTrackingStarted(runner);

      expect(runner.scripts, hasLength(1));
    });

    test('does nothing when FCM has no token for this device', () async {
      gateway.currentToken = null;
      final runner = _Runner();
      await service.start();

      await service.onAgentTrackingStarted(runner);

      expect(runner.scripts, isEmpty);
    });
  });

  group('registration never fails the connection', () {
    test('a throwing token lookup is swallowed', () async {
      gateway.tokenError = StateError('no play services');
      await service.start();

      await expectLater(
        service.onAgentTrackingStarted(_Runner()),
        completes,
      );
    });

    test('a dead transport is swallowed', () async {
      await service.start();

      await expectLater(
        service.onAgentTrackingStarted(_BrokenRunner()),
        completes,
      );
    });

    test('a plugin that fails to initialize does not fail start()', () async {
      presenter.initializeError = StateError('channel registration failed');

      await expectLater(service.start(), completes);
    });
  });

  group('foreground messages are drawn by this app', () {
    test('shows a notification FCM would have swallowed', () async {
      // FCM does not draw a tray notification while the app is in front.
      // Without this the user sitting on another screen is simply ignored.
      await service.start();

      gateway.emitForeground(alertMessage());
      await pumpEventQueue();

      expect(presenter.shown, hasLength(1));
      expect(presenter.shown.single.title, 'claude needs you');
      expect(presenter.shown.single.body, 'helm-a1b2c3d4 - %7 - blocked');
    });

    test('carries a payload that resolves back to the same session', () async {
      await service.start();

      gateway.emitForeground(alertMessage());
      await pumpEventQueue();

      final restored =
          SessionAlert.fromPayload(presenter.shown.single.payload);
      expect(restored?.sessionName, 'helm-a1b2c3d4');
      expect(restored?.agent, 'claude');
    });

    test('does not open the session by itself', () async {
      // The user is looking at something else. Yanking them to another tab
      // because a background agent moved would be the app taking over.
      await service.start();

      gateway.emitForeground(alertMessage());
      await pumpEventQueue();

      expect(opened, isEmpty);
    });

    test('a message with neither title nor body draws nothing', () async {
      await service.start();

      gateway.emitForeground(
        const PushMessage(data: {'session': 'quiet'}),
      );
      await pumpEventQueue();

      expect(presenter.shown, isEmpty);
    });
  });

  group('a warm tap opens the session it named', () {
    test('opens the session from an FCM tap', () async {
      await service.start();

      gateway.emitTap(alertMessage());
      await pumpEventQueue();

      expect(opened, hasLength(1));
      expect(opened.single.sessionName, 'helm-a1b2c3d4');
    });

    test('opens the session from a tap on a locally drawn notification',
        () async {
      await service.start();

      presenter.onTap!(
        const SessionAlert(sessionName: 'drawn-locally').toPayload(),
      );
      await pumpEventQueue();

      expect(opened.single.sessionName, 'drawn-locally');
    });

    test('a local tap with a null payload opens nothing', () async {
      await service.start();

      presenter.onTap!(null);
      await pumpEventQueue();

      expect(opened, isEmpty);
    });
  });

  group('dispose', () {
    test('stops reacting to messages that arrive afterwards', () async {
      await service.start();
      await service.dispose();

      gateway.emitTap(alertMessage());
      gateway.emitForeground(alertMessage());
      await pumpEventQueue();

      expect(opened, isEmpty);
      expect(presenter.shown, isEmpty);
    });
  });
}
