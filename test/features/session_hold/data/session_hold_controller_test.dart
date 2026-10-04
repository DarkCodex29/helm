import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/session_hold/data/session_hold_controller.dart';
import 'package:helm/features/session_hold/domain/session_hold_state.dart';

import '../../../helpers/fake_foreground_service_host.dart';

/// A session that is connected unless a test says otherwise.
({ValueNotifier<ConnectionStatus> status, HoldableSession session}) _session({
  String name = 'helm-a1b2c3d4',
  String host = 'Mac Studio',
  ConnectionStatus status = ConnectionStatus.connected,
}) {
  final notifier = ValueNotifier(status);
  return (
    status: notifier,
    session: (sessionName: name, hostName: host, status: notifier),
  );
}

void main() {
  late FakeForegroundServiceHost host;
  late SessionHoldController controller;

  setUp(() {
    host = FakeForegroundServiceHost();
    controller = SessionHoldController(host: host);
  });

  tearDown(() async {
    await controller.dispose();
    await host.close();
  });

  group('starting a hold', () {
    test('nothing is held until the user asks for it', () async {
      final s = _session();

      // A session reaching `connected` is the moment a hold BECOMES
      // possible, and it must not by itself be the moment one starts.
      // Nothing in this class watches for that transition: the only two
      // ways in are `hold` (a tap) and `holdOnConnect` (a profile
      // preference the user set), and a status change is neither.
      s.status.value = ConnectionStatus.connecting;
      s.status.value = ConnectionStatus.connected;

      expect(host.starts, isEmpty);
      expect(controller.state, const SessionHoldState.released());
    });

    test('holding names the session the service is actually holding', () async {
      final s = _session(name: 'helm-deploy', host: 'Mac Studio');

      await controller.hold(s.session);

      expect(host.starts, hasLength(1));
      expect(host.starts.single.sessionName, 'helm-deploy');
      expect(host.starts.single.hostName, 'Mac Studio');
      expect(controller.state, const SessionHoldState.held('helm-deploy'));
    });

    test('a session that is not connected cannot be held', () async {
      final s = _session(status: ConnectionStatus.connecting);

      await controller.hold(s.session);

      expect(host.starts, isEmpty);
      expect(controller.state, const SessionHoldState.released());
    });

    test('holding the same session twice starts one service', () async {
      final s = _session();

      await controller.hold(s.session);
      await controller.hold(s.session);

      expect(host.starts, hasLength(1));
      expect(controller.state, const SessionHoldState.held('helm-a1b2c3d4'));
    });

    test('two sessions sharing a label are still two sessions', () async {
      // Reached with two unnamed tabs on one profile: both fall back to
      // the profile's name for the notification, so a label-keyed
      // "already holding this" check would silently refuse the second
      // hold and leave the first one running under a notification the
      // user would read as the second.
      final first = _session(name: 'Mac Studio');
      final second = _session(name: 'Mac Studio');

      await controller.hold(first.session);
      await controller.hold(second.session);

      expect(host.starts, hasLength(2));

      // The hold is on the SECOND session now, so the first one dying
      // must not tear it down.
      first.status.value = ConnectionStatus.disconnected;
      await pumpEventQueue();
      expect(controller.state, const SessionHoldState.held('Mac Studio'));

      second.status.value = ConnectionStatus.disconnected;
      await pumpEventQueue();
      expect(controller.state, const SessionHoldState.released());
    });

    test('holding a second session replaces the first rather than stacking', () async {
      final first = _session(name: 'helm-one');
      final second = _session(name: 'helm-two');

      await controller.hold(first.session);
      await controller.hold(second.session);

      expect(host.starts.map((s) => s.sessionName), ['helm-one', 'helm-two']);
      expect(controller.state, const SessionHoldState.held('helm-two'));

      // The first session is no longer watched: its disconnect must not
      // tear down a hold that now belongs to the second.
      first.status.value = ConnectionStatus.disconnected;
      expect(controller.state, const SessionHoldState.held('helm-two'));
    });

    test('a platform that refuses is reported, not thrown', () async {
      host.startSucceeds = false;
      final s = _session();

      await controller.hold(s.session);

      expect(controller.state, const SessionHoldState.unavailable());
      // Nothing is left running on a refusal.
      expect(host.running, isFalse);
    });
  });

  group('stopping a hold', () {
    test('STOP in the notification releases the hold', () async {
      final s = _session();
      await controller.hold(s.session);

      host.tapStopAction();
      await pumpEventQueue();

      expect(controller.state, const SessionHoldState.released());
      expect(host.running, isFalse);
    });

    test('STOP leaves the session watchable again', () async {
      final s = _session();
      await controller.hold(s.session);

      host.tapStopAction();
      await pumpEventQueue();

      // The listener was detached, so the session's later disconnect
      // cannot drive a second teardown of a hold nobody holds.
      final stopsAfterRelease = host.stopCount;
      s.status.value = ConnectionStatus.disconnected;
      await pumpEventQueue();

      expect(host.stopCount, stopsAfterRelease);
      expect(controller.state, const SessionHoldState.released());
    });

    test('releasing by hand stops the service', () async {
      final s = _session();
      await controller.hold(s.session);

      await controller.release();

      expect(host.stopCount, 1);
      expect(host.running, isFalse);
      expect(controller.state, const SessionHoldState.released());
    });

    test('a held session that disconnects stops the service', () async {
      final s = _session();
      await controller.hold(s.session);

      // The transport died — the multiplexer host rebooted, the network
      // dropped, anything. A service still running now is holding open a
      // process for a connection that no longer exists.
      s.status.value = ConnectionStatus.disconnected;
      await pumpEventQueue();

      expect(controller.state, const SessionHoldState.released());
      expect(host.running, isFalse);
      expect(host.stopCount, 1);
    });

    test('a held session that errors stops the service', () async {
      final s = _session();
      await controller.hold(s.session);

      s.status.value = ConnectionStatus.error;
      await pumpEventQueue();

      expect(controller.state, const SessionHoldState.released());
      expect(host.running, isFalse);
    });

    test('closing the held tab does not outlive its status notifier', () async {
      final s = _session();
      await controller.hold(s.session);

      // Exactly what `TerminalSession.dispose` does, in exactly that
      // order (terminal_session.dart:1081-1082): set the status, then
      // dispose the notifier in the same synchronous call. A controller
      // that deferred `removeListener` to a microtask would run it
      // against a disposed ChangeNotifier and throw in debug — turning an
      // ordinary tab close into a crash.
      s.status.value = ConnectionStatus.disconnected;
      s.status.dispose();
      await pumpEventQueue();

      expect(controller.state, const SessionHoldState.released());
      expect(host.running, isFalse);

      // And the controller must still be usable afterwards: `_detach` on
      // a hold that is already gone must not reach the disposed notifier.
      await expectLater(controller.release(), completes);
    });

    test('disposing releases whatever was held', () async {
      final s = _session();
      await controller.hold(s.session);

      await controller.dispose();

      expect(host.running, isFalse);
      expect(controller.state, const SessionHoldState.released());
    });
  });

  group('honest state', () {
    test('a service the OS took is not reported as held', () async {
      final s = _session();
      await controller.hold(s.session);
      expect(controller.state.isHolding, isTrue);

      // No event, no callback, no warning — which is exactly how an
      // aggressive OEM power manager removes a foreground service.
      host.killFromOutside();
      await controller.onAppResumed();

      expect(controller.state, const SessionHoldState.released());
    });

    test('a service still running is still reported as held', () async {
      final s = _session();
      await controller.hold(s.session);

      await controller.onAppResumed();

      expect(controller.state, const SessionHoldState.held('helm-a1b2c3d4'));
    });

    test('resuming with nothing held asks the platform nothing', () async {
      await controller.onAppResumed();

      expect(controller.state, const SessionHoldState.released());
      expect(host.stopCount, 0);
    });
  });

  group('holding because the profile asked for it', () {
    test('a connect the profile asked to hold is held', () async {
      final s = _session(name: 'helm-deploy', host: 'Mac Studio');

      await controller.holdOnConnect(s.session);

      expect(host.starts, hasLength(1));
      expect(host.starts.single.sessionName, 'helm-deploy');
      expect(controller.state, const SessionHoldState.held('helm-deploy'));
    });

    test('a session that never reached connected is not held', () async {
      // The connect failed, or is still in flight. The automatic path is
      // held to exactly the same rule as the manual one: there is nothing
      // to hold open until there is something open.
      final s = _session(status: ConnectionStatus.connecting);

      await controller.holdOnConnect(s.session);

      expect(host.starts, isEmpty);
      expect(controller.state, const SessionHoldState.released());
    });

    test(
      'a platform that refuses an automatic hold reports unavailable, and '
      'never a hold that is not there',
      () async {
        host.startSucceeds = false;
        final s = _session();

        await controller.holdOnConnect(s.session);

        expect(controller.state, const SessionHoldState.unavailable());
        expect(host.running, isFalse);
      },
    );

    test(
      'a hold the user turned off by hand does not come back for that '
      'session - the preference decides what happens on the NEXT connect, '
      'and never overrules the user in the moment',
      () async {
        final s = _session();

        await controller.holdOnConnect(s.session);
        expect(controller.state.isHolding, isTrue);

        await controller.release();

        // The same session, asked for again by the same automatic path.
        await controller.holdOnConnect(s.session);

        expect(host.starts, hasLength(1));
        expect(controller.state, const SessionHoldState.released());
      },
    );

    test('STOP in the notification refuses further automatic holds too', () async {
      // The notification's own STOP button is the same gesture as the
      // toolbar pin, reached through a different surface. Treating it as
      // weaker would make a control the user can see from outside the app
      // mean less than one they can only reach inside it.
      final s = _session();
      await controller.holdOnConnect(s.session);

      host.tapStopAction();
      await pumpEventQueue();

      await controller.holdOnConnect(s.session);

      expect(host.starts, hasLength(1));
      expect(controller.state, const SessionHoldState.released());
    });

    test(
      'turning one session off says nothing about another - the refusal is '
      'per session, not a mode the whole app enters',
      () async {
        final first = _session(name: 'helm-one');
        final second = _session(name: 'helm-two');

        await controller.holdOnConnect(first.session);
        await controller.release();

        await controller.holdOnConnect(second.session);

        expect(host.starts.map((s) => s.sessionName), ['helm-one', 'helm-two']);
        expect(controller.state, const SessionHoldState.held('helm-two'));
      },
    );

    test(
      'a hold that ended because the session disconnected is taken again on '
      'the next connect - a dropped connection is not the user declining',
      () async {
        final s = _session();

        await controller.holdOnConnect(s.session);
        s.status.value = ConnectionStatus.disconnected;
        await pumpEventQueue();
        expect(controller.state, const SessionHoldState.released());

        s.status.value = ConnectionStatus.connected;
        await controller.holdOnConnect(s.session);

        expect(host.starts, hasLength(2));
        expect(controller.state.isHolding, isTrue);
      },
    );

    test(
      'asking for a hold by hand clears the refusal, so the preference is '
      'honoured again afterwards',
      () async {
        final s = _session();

        await controller.holdOnConnect(s.session);
        await controller.release();

        // The user changed their mind and tapped the pin back on. That is
        // the exact opposite of the gesture that set the refusal, so the
        // refusal must not survive it.
        await controller.hold(s.session);
        expect(controller.state.isHolding, isTrue);

        // Torn down by the connection dying, which declines nothing.
        s.status.value = ConnectionStatus.disconnected;
        await pumpEventQueue();
        s.status.value = ConnectionStatus.connected;

        await controller.holdOnConnect(s.session);

        expect(host.starts, hasLength(3));
        expect(controller.state.isHolding, isTrue);
      },
    );

    test('a disposed controller holds nothing on connect', () async {
      final s = _session();
      await controller.dispose();

      await controller.holdOnConnect(s.session);

      expect(host.starts, isEmpty);
    });
  });

  group('idle timeout', () {
    test('the idle timeout is not restarted by the preference', () {
      // Constraint the whole feature rests on: an automatic START must
      // never become an automatic RESTART. The four-hour bound exists
      // because "the user forgot" has no natural end, and a preference
      // that re-armed the hold after the bound expired would delete that
      // bound entirely while looking like it was still there.
      fakeAsync((async) {
        final fake = FakeForegroundServiceHost();
        final held = SessionHoldController(
          host: fake,
          idleTimeout: const Duration(hours: 4),
        );
        final s = _session();

        held.holdOnConnect(s.session);
        async.flushMicrotasks();
        expect(fake.starts, hasLength(1));

        async.elapse(const Duration(hours: 5));
        async.flushMicrotasks();

        expect(held.state, const SessionHoldState.released());
        expect(fake.running, isFalse);

        // Nothing started a second service on its own in the meantime.
        async.elapse(const Duration(hours: 12));
        async.flushMicrotasks();
        expect(fake.starts, hasLength(1));
        expect(fake.running, isFalse);
      });
    });

    test('a forgotten hold tears itself down', () {
      fakeAsync((async) {
        final fake = FakeForegroundServiceHost();
        final held = SessionHoldController(
          host: fake,
          idleTimeout: const Duration(hours: 4),
        );
        final s = _session();

        held.hold(s.session);
        async.flushMicrotasks();
        expect(held.state.isHolding, isTrue);

        // Just short of the deadline: still held. Asserted so the test
        // proves a TIMEOUT rather than merely an eventual teardown.
        async.elapse(const Duration(hours: 3, minutes: 59));
        async.flushMicrotasks();
        expect(held.state.isHolding, isTrue);

        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();

        expect(held.state, const SessionHoldState.released());
        expect(fake.running, isFalse);
      });
    });

    test('coming back to the app restarts the clock', () {
      fakeAsync((async) {
        final fake = FakeForegroundServiceHost();
        final held = SessionHoldController(
          host: fake,
          idleTimeout: const Duration(hours: 4),
        );
        final s = _session();

        held.hold(s.session);
        async.flushMicrotasks();

        async.elapse(const Duration(hours: 3));
        held.onAppResumed();
        async.flushMicrotasks();

        // Three more hours: past the original deadline, short of the new
        // one. The user was present an hour ago, so this hold is not
        // forgotten.
        async.elapse(const Duration(hours: 3));
        async.flushMicrotasks();
        expect(held.state.isHolding, isTrue);

        async.elapse(const Duration(hours: 2));
        async.flushMicrotasks();
        expect(held.state, const SessionHoldState.released());
      });
    });
  });
}
