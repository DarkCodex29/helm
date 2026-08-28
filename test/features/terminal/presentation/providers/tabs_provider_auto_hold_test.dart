import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/session_hold/data/session_hold_controller.dart';
import 'package:helm/features/session_hold/presentation/session_hold_provider.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../helpers/fake_foreground_service_host.dart';
import '../../../../helpers/fake_secure_storage.dart';
import '../../../../helpers/fake_ssh_service.dart';

/// A profile that asked for its sessions to be held in the background.
const _holdingProfile = ConnectionProfile(
  id: 'p-hold',
  name: 'Mac Studio',
  host: '192.168.1.10',
  username: 'gian',
  holdInBackground: true,
);

/// The same profile, without the preference. The default for everyone.
const _plainProfile = ConnectionProfile(
  id: 'p-plain',
  name: 'Contabo VPS',
  host: '158.220.106.131',
  username: 'deployer',
);

/// Stands in for an unroutable host: a transport-level failure raised by
/// `connectAndOpenShell`, which is what `TerminalSession.connect` rethrows.
class _SocketFailure implements Exception {
  const _SocketFailure();

  @override
  String toString() => 'SocketException: No route to host';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSSHService ssh;
  late FakeForegroundServiceHost host;
  late SessionHoldController holdController;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppConstants.profilesStorageKey: [
        jsonEncode(_holdingProfile.toJson()),
        jsonEncode(_plainProfile.toJson()),
      ],
    });

    ssh = FakeSSHService();
    host = FakeForegroundServiceHost();
    holdController = SessionHoldController(host: host);

    container = ProviderContainer(
      overrides: [
        sshServiceProvider.overrideWithValue(ssh),
        sshKeyServiceProvider.overrideWithValue(
          SSHKeyService(
            storage: FakeSecureStorage({
              AppConstants.sshPrivateKeyStorageKey: 'fake-pem',
            }),
          ),
        ),
        sessionHoldControllerProvider.overrideWithValue(holdController),
      ],
    );
  });

  tearDown(() async {
    for (final tab in container.read(tabsProvider).tabs) {
      await tab.session.dispose();
    }
    container.dispose();
    await holdController.dispose();
    await host.close();
  });

  group('TabsNotifier.addTab and the background-hold preference', () {
    test(
      'a connect that FAILED holds nothing, even for a profile that asked '
      'for a hold — a foreground service over a connection that was never '
      'established is a notification about nothing',
      () async {
        ssh.queueConnectError(const _SocketFailure());

        await container.read(tabsProvider.notifier).addTab(_holdingProfile);

        // The tab is there, carrying the failure, exactly as before.
        final tabs = container.read(tabsProvider).tabs;
        expect(tabs, hasLength(1));
        expect(
          tabs.single.session.statusNotifier.value,
          ConnectionStatus.error,
        );

        expect(host.starts, isEmpty);
        expect(host.running, isFalse);
        expect(holdController.state.isHolding, isFalse);
      },
    );

    test(
      'a profile that did not ask for a hold gets none — this is the state '
      'every existing install upgrades into',
      () async {
        ssh.queueConnectError(const _SocketFailure());

        await container.read(tabsProvider.notifier).addTab(_plainProfile);

        expect(host.starts, isEmpty);
        expect(holdController.state, isA<Object>());
        expect(holdController.state.isHolding, isFalse);
      },
    );

    test(
      'auto-connecting the default profile on launch holds nothing when the '
      'connect fails',
      () async {
        // Launch is the one path where nobody tapped anything. It must be
        // held to the same rule as every other: no connection, no service.
        SharedPreferences.setMockInitialValues({
          AppConstants.profilesStorageKey: [
            jsonEncode(
              _holdingProfile.copyWith(isDefault: true).toJson(),
            ),
          ],
        });
        ssh.queueConnectError(const _SocketFailure());

        await container
            .read(tabsProvider.notifier)
            .autoConnectDefault(recoveryPending: false);

        expect(container.read(tabsProvider).tabs, hasLength(1));
        expect(host.starts, isEmpty);
      },
    );
  });
}
