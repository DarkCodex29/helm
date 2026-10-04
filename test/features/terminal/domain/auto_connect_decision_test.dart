import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/domain/auto_connect_decision.dart';

ConnectionProfile _profile(String id, {bool isDefault = false}) =>
    ConnectionProfile(
      id: id,
      name: id,
      host: 'host-$id',
      username: 'deployer',
      isDefault: isDefault,
    );

void main() {
  group('decideAutoConnect', () {
    test('opens the profile the user explicitly marked as default', () {
      final marked = _profile('b', isDefault: true);

      final decision = decideAutoConnect(
        profiles: [_profile('a'), marked, _profile('c')],
        openProfileIds: const [],
        recoveryPending: false,
      );

      expect(decision, isA<AutoConnectStart>());
      expect((decision as AutoConnectStart).profile.id, 'b');
    });

    test(
      'declines when NO profile is marked default, even though profiles '
      'exist - the promise is attached to the flag, not to having a '
      'profile at all, so an unmarked list must leave launch untouched',
      () {
        // ConnectionProfileRepository.getDefault() answers this question
        // differently: with nothing marked, it hands back the FIRST
        // profile so callers like shortcut-opening always get something
        // to work with. Auto-connect must not inherit that generosity —
        // reusing it here would silently connect a profile the user never
        // marked, which is exactly the surprise the isDefault flag exists
        // to gate.
        final decision = decideAutoConnect(
          profiles: [_profile('a'), _profile('b')],
          openProfileIds: const [],
          recoveryPending: false,
        );

        expect(decision, isA<AutoConnectSkip>());
        expect(
          (decision as AutoConnectSkip).reason,
          AutoConnectSkipReason.noDefaultProfile,
        );
      },
    );

    test('declines when there are no profiles at all', () {
      final decision = decideAutoConnect(
        profiles: const [],
        openProfileIds: const [],
        recoveryPending: false,
      );

      expect(
        (decision as AutoConnectSkip).reason,
        AutoConnectSkipReason.noDefaultProfile,
      );
    });

    test(
      'stands down while a crash-recovery offer is outstanding - the '
      'restore would reopen the very same profile, and two sessions is '
      'the failure mode this whole decision exists to prevent',
      () {
        final decision = decideAutoConnect(
          profiles: [_profile('a', isDefault: true)],
          openProfileIds: const [],
          recoveryPending: true,
        );

        expect(
          (decision as AutoConnectSkip).reason,
          AutoConnectSkipReason.recoveryPending,
        );
      },
    );

    test(
      'stands down when a session for that profile is already open - a '
      'completed recovery leaves exactly that state behind',
      () {
        final decision = decideAutoConnect(
          profiles: [_profile('a', isDefault: true)],
          openProfileIds: const ['a'],
          recoveryPending: false,
        );

        expect(
          (decision as AutoConnectSkip).reason,
          AutoConnectSkipReason.alreadyOpen,
        );
      },
    );

    test(
      'an open session for a DIFFERENT profile does not block the default '
      'one - the guard is per profile, not "any tab exists"',
      () {
        final decision = decideAutoConnect(
          profiles: [_profile('a', isDefault: true), _profile('z')],
          openProfileIds: const ['z'],
          recoveryPending: false,
        );

        expect(decision, isA<AutoConnectStart>());
        expect((decision as AutoConnectStart).profile.id, 'a');
      },
    );

    test(
      'a missing default outranks a pending recovery as the reported '
      'reason - there is nothing to auto-connect to either way',
      () {
        final decision = decideAutoConnect(
          profiles: [_profile('a')],
          openProfileIds: const [],
          recoveryPending: true,
        );

        expect(
          (decision as AutoConnectSkip).reason,
          AutoConnectSkipReason.noDefaultProfile,
        );
      },
    );

    test(
      'with corrupt data marking two profiles default, the first wins - '
      'the same tie-break the repository already applies',
      () {
        final decision = decideAutoConnect(
          profiles: [
            _profile('first', isDefault: true),
            _profile('second', isDefault: true),
          ],
          openProfileIds: const [],
          recoveryPending: false,
        );

        expect((decision as AutoConnectStart).profile.id, 'first');
      },
    );
  });
}
