import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/domain/auto_connect_decision.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../helpers/fake_secure_storage.dart';
import '../../../../helpers/fake_ssh_service.dart';

const _defaultProfile = ConnectionProfile(
  id: 'p-default',
  name: 'VPS',
  host: '158.220.106.131',
  username: 'deployer',
  isDefault: true,
);

const _otherProfile = ConnectionProfile(
  id: 'p-other',
  name: 'Laptop',
  host: '10.0.0.9',
  username: 'gian',
);

void _seedProfiles(List<ConnectionProfile> profiles) {
  SharedPreferences.setMockInitialValues({
    AppConstants.profilesStorageKey: profiles
        .map((p) => jsonEncode(p.toJson()))
        .toList(),
  });
}

/// A container whose SSH surface is entirely faked, with a private key
/// already present so [TabsNotifier.addTab] gets past its key check.
ProviderContainer _container(FakeSSHService ssh) => ProviderContainer(
  overrides: [
    sshServiceProvider.overrideWithValue(ssh),
    sshKeyServiceProvider.overrideWithValue(
      SSHKeyService(
        storage: FakeSecureStorage({
          AppConstants.sshPrivateKeyStorageKey: 'fake-pem',
        }),
      ),
    ),
  ],
);

void main() {
  late FakeSSHService ssh;
  late ProviderContainer container;

  setUp(() {
    ssh = FakeSSHService();
    container = _container(ssh);
  });

  tearDown(() async {
    for (final tab in container.read(tabsProvider).tabs) {
      await tab.session.dispose();
    }
    container.dispose();
  });

  group('TabsNotifier.autoConnectDefault', () {
    test(
      'opens a session for the profile the user marked default, with no '
      'user action — this is the whole point of the "Opens automatically '
      'on launch" copy the profile editor already shows',
      () async {
        _seedProfiles([_otherProfile, _defaultProfile]);
        ssh.queueConnectError(const SocketFailure());

        final decision = await container
            .read(tabsProvider.notifier)
            .autoConnectDefault(recoveryPending: false);

        expect(decision, isA<AutoConnectStart>());
        expect(container.read(tabsProvider).tabs, hasLength(1));
        expect(
          container.read(tabsProvider).tabs.single.profile.id,
          'p-default',
        );
        // The host that was actually dialed, not merely the tab's label.
        expect(ssh.connectCalls.single.profile.id, 'p-default');
      },
    );

    test(
      'an unreachable host does NOT throw out of auto-connect and does NOT '
      'strand Home — the tab is still there, carrying the failure',
      () async {
        _seedProfiles([_defaultProfile]);
        ssh.queueConnectError(const SocketFailure());

        // No expect(..., throwsA(...)) wrapper on purpose: an exception
        // escaping here would propagate out of HomeScreen's post-frame
        // callback, and an unroutable host on launch would take the app
        // down instead of the session.
        await container
            .read(tabsProvider.notifier)
            .autoConnectDefault(recoveryPending: false);

        final tabs = container.read(tabsProvider).tabs;
        expect(tabs, hasLength(1));
        expect(
          tabs.single.session.statusNotifier.value,
          ConnectionStatus.error,
        );
      },
    );

    test(
      'stands down while a crash-recovery offer is outstanding — accepting '
      'that offer reopens this very profile, and nothing must dial in '
      'parallel with it',
      () async {
        _seedProfiles([_defaultProfile]);

        final decision = await container
            .read(tabsProvider.notifier)
            .autoConnectDefault(recoveryPending: true);

        expect(
          (decision as AutoConnectSkip).reason,
          AutoConnectSkipReason.recoveryPending,
        );
        expect(container.read(tabsProvider).tabs, isEmpty);
        expect(ssh.connectCalls, isEmpty);
      },
    );

    test(
      'does not open a SECOND session when a recovered one is already on '
      'that profile — one session, not one per launch path',
      () async {
        _seedProfiles([_defaultProfile]);
        ssh.queueConnectError(const SocketFailure());

        // Stand in for a completed crash recovery: a tab already exists
        // for the default profile before auto-connect is evaluated.
        await container.read(tabsProvider.notifier).addTab(_defaultProfile);
        expect(ssh.connectCalls, hasLength(1));

        final decision = await container
            .read(tabsProvider.notifier)
            .autoConnectDefault(recoveryPending: false);

        expect(
          (decision as AutoConnectSkip).reason,
          AutoConnectSkipReason.alreadyOpen,
        );
        expect(container.read(tabsProvider).tabs, hasLength(1));
        expect(ssh.connectCalls, hasLength(1));
      },
    );

    test(
      'with NO profile marked default, launch is left exactly as it was — '
      'no tab, no dial, today empty state',
      () async {
        _seedProfiles([_otherProfile]);

        final decision = await container
            .read(tabsProvider.notifier)
            .autoConnectDefault(recoveryPending: false);

        expect(
          (decision as AutoConnectSkip).reason,
          AutoConnectSkipReason.noDefaultProfile,
        );
        expect(container.read(tabsProvider).tabs, isEmpty);
        expect(ssh.connectCalls, isEmpty);
      },
    );

    test('with no profiles saved at all, it dials nothing', () async {
      _seedProfiles(const []);

      final decision = await container
          .read(tabsProvider.notifier)
          .autoConnectDefault(recoveryPending: false);

      expect(
        (decision as AutoConnectSkip).reason,
        AutoConnectSkipReason.noDefaultProfile,
      );
      expect(ssh.connectCalls, isEmpty);
    });
  });
}

/// Stands in for what an unroutable host produces: a transport-level
/// failure raised by `connectAndOpenShell`.
class SocketFailure implements Exception {
  const SocketFailure();

  @override
  String toString() => 'SocketException: No route to host';
}
