// Opening a tab must not dial before it knows how wide the screen is.
//
// This is the launch sequence that produced the reported defect: HomeScreen
// runs auto-connect from a post-frame callback, addTab creates the session
// and assigns state, and that assignment only SCHEDULES the rebuild that
// mounts HelmTerminalView. connect() therefore runs while no view exists,
// and reading a size at that moment yields xterm's 80x24 constructor
// default. Measured against the real host: a multiplexer handed an
// 80-column PTY paints 80 columns, so on a 51-column phone 29 columns fall
// off the right edge.
//
// addTab is the only place that can close that window, because it is the
// only place that knows a view is about to render this session. These
// tests pin that it does.
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

const _profile = ConnectionProfile(
  id: 'p-default',
  name: 'VPS',
  host: '158.220.106.131',
  username: 'deployer',
  isDefault: true,
);

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
    SharedPreferences.setMockInitialValues({
      AppConstants.profilesStorageKey: [jsonEncode(_profile.toJson())],
    });
    ssh = FakeSSHService();
    container = _container(ssh);
  });

  tearDown(() => container.dispose());

  test(
    'addTab does not open a PTY until the tab it just created has reported '
    'a real viewport size',
    () async {
      final notifier = container.read(tabsProvider.notifier);

      final opening = notifier.addTab(_profile);
      // Let every microtask the key lookup and state assignment queue run.
      // The view still does not exist — in the app it is a frame away.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        ssh.connectCalls,
        isEmpty,
        reason:
            'addTab dialed before anything could tell it the screen size, so '
            'the PTY would be opened at the 80x24 default',
      );

      // The tab exists and is rendered from the first frame, exactly as
      // addTab's own doc promises — it just is not connected yet.
      expect(container.read(tabsProvider).tabs, hasLength(1));

      // The view lays out and reports what it renders.
      final session = container.read(tabsProvider).tabs.single.session;
      session.onResize(51, 29);
      await opening;

      expect(ssh.connectCalls, hasLength(1));
      expect(ssh.connectCalls.single.columns, 51);
      expect(ssh.connectCalls.single.rows, 29);
    },
  );

  test(
    'a tab closed before its viewport ever reported still finishes opening '
    'rather than hanging on a view that will never arrive',
    () async {
      final notifier = container.read(tabsProvider.notifier);

      final opening = notifier.addTab(_profile);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(ssh.connectCalls, isEmpty);

      final tab = container.read(tabsProvider).tabs.single;
      await notifier.removeTab(tab.id);
      await opening;

      expect(container.read(tabsProvider).tabs, isEmpty);
    },
  );
}
