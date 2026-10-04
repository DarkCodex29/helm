import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../helpers/fake_secure_storage.dart';
import '../../../../helpers/fake_ssh_service.dart';

const _defaultProfile = ConnectionProfile(
  id: 'p-default',
  name: 'Mac',
  host: '100.64.0.9',
  username: 'gian',
  isDefault: true,
);

const _otherProfile = ConnectionProfile(
  id: 'p-other',
  name: 'VPS',
  host: '158.220.106.131',
  username: 'deployer',
);

void _seedProfiles(List<ConnectionProfile> profiles) {
  SharedPreferences.setMockInitialValues({
    AppConstants.profilesStorageKey: profiles
        .map((p) => jsonEncode(p.toJson()))
        .toList(),
  });
}

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

  group('TabsNotifier.openSessionNamed', () {
    test('attaches a tab to the session the notification named', () async {
      _seedProfiles([_defaultProfile]);
      ssh.queueConnectError(Exception('no host in a unit test'));

      await container
          .read(tabsProvider.notifier)
          .openSessionNamed('helm-a1b2c3d4');

      final tabs = container.read(tabsProvider).tabs;
      expect(tabs, hasLength(1));
      expect(tabs.single.session.tmuxSessionName, 'helm-a1b2c3d4');
    });

    test('dials the default profile, since the Mac cannot name one', () async {
      // The notifier runs on the Mac and knows nothing about helm's
      // profiles — they are phone-side records with phone-minted UUIDs.
      // Requiring one in the payload would make the sender depend on state
      // it cannot see.
      _seedProfiles([_otherProfile, _defaultProfile]);
      ssh.queueConnectError(Exception('no host in a unit test'));

      await container
          .read(tabsProvider.notifier)
          .openSessionNamed('helm-a1b2c3d4');

      expect(container.read(tabsProvider).tabs.single.profile.id, 'p-default');
    });

    test('focuses the tab already on that session instead of opening a second',
        () async {
      // resolveSessionName already owns this rule; the point of the test is
      // that the notification path goes THROUGH it rather than around it.
      // Two tabs on one session render the same screen and fight over the
      // remote PTY size.
      _seedProfiles([_defaultProfile]);
      ssh.queueConnectError(Exception('no host in a unit test'));
      ssh.queueConnectError(Exception('no host in a unit test'));

      final notifier = container.read(tabsProvider.notifier);
      await notifier.addTab(_defaultProfile, tmuxSessionName: 'work');
      await notifier.addTab(_defaultProfile, tmuxSessionName: 'other');
      expect(container.read(tabsProvider).activeIndex, 1);

      await notifier.openSessionNamed('work');

      expect(container.read(tabsProvider).tabs, hasLength(2));
      expect(container.read(tabsProvider).activeIndex, 0);
    });

    test('opens nothing when no profile is saved, and does not throw',
        () async {
      _seedProfiles([]);

      await expectLater(
        container.read(tabsProvider.notifier).openSessionNamed('orphan'),
        completes,
      );
      expect(container.read(tabsProvider).tabs, isEmpty);
    });

    test('opens nothing for an empty session name', () async {
      // A malformed payload degrades to the ordinary home screen rather
      // than opening a tab attached to nothing.
      _seedProfiles([_defaultProfile]);

      await container.read(tabsProvider.notifier).openSessionNamed('');

      expect(container.read(tabsProvider).tabs, isEmpty);
    });
  });
}
