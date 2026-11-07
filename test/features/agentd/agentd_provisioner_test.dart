@Timeout(Duration(seconds: 30))
library;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/agentd/data/agentd_provisioner.dart';
import 'package:helm/features/agentd/data/agentd_providers.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';

import '../../helpers/fake_secure_storage.dart';
import '../../helpers/fake_sftp_session.dart';
import '../../helpers/fake_ssh_service.dart';

const _token = 'FAKEfakeFAKEfakeFAKEfakeFAKEfakeFAKEfakeFAK';

ConnectionProfile _profile(String id) =>
    ConnectionProfile(id: id, name: 'n', host: 'h.test', username: 'u');

TerminalTab _tab(String tabId, String profileId) {
  final session = TerminalSession(
    profile: _profile(profileId),
    sshService: FakeSSHService(),
  );
  addTearDown(session.dispose);
  return TerminalTab(
    id: tabId,
    title: tabId,
    session: session,
    profile: _profile(profileId),
  );
}

FakeSftpSession _hostWithToken() => FakeSftpSession(
  home: '/home/u',
  files: {'/home/u/.helm-agentd/token': FakeRemoteFile(_token.codeUnits)},
);

void main() {
  late FakeSecureStorage storage;
  late int opens;
  late FakeSftpSession sftp;
  late ProviderContainer c;

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    storage = FakeSecureStorage();
    opens = 0;
    sftp = _hostWithToken();
    c = ProviderContainer(
      overrides: [
        agentdSecureStorageProvider.overrideWithValue(storage),
        agentdSftpOpenerProvider.overrideWithValue((tab) {
          opens++;
          return Future.value(sftp);
        }),
      ],
    );
    addTearDown(c.dispose);
  });

  AgentdProvisioner prov() => c.read(agentdProvisionerProvider.notifier);

  test('provisions once on the first connect when no token exists', () async {
    final tab = _tab('t1', 'p1');
    prov().track([tab]);
    await settle();
    expect(opens, 0, reason: 'not connected yet');

    tab.session.statusNotifier.value = ConnectionStatus.connected;
    await settle();

    expect(opens, 1);
    expect(await c.read(agentdTokenStoreProvider).read('p1'), _token);
  });

  test('an already connected tab provisions when first tracked', () async {
    final tab = _tab('t1', 'p1');
    tab.session.statusNotifier.value = ConnectionStatus.connected;
    prov().track([tab]);
    await settle();
    expect(opens, 1);
  });

  test('does not provision when a token already exists', () async {
    await c.read(agentdTokenStoreProvider).write('p1', _token);
    final tab = _tab('t1', 'p1');
    prov().track([tab]);
    tab.session.statusNotifier.value = ConnectionStatus.connected;
    await settle();
    expect(opens, 0);
  });

  test('notFound is silent and not retried this run', () async {
    sftp = FakeSftpSession(home: '/home/u');
    final tab = _tab('t1', 'p1');
    prov().track([tab]);
    tab.session.statusNotifier.value = ConnectionStatus.connected;
    await settle();
    expect(opens, 1);
    expect(await c.read(agentdTokenStoreProvider).read('p1'), isNull);

    tab.session.statusNotifier.value = ConnectionStatus.disconnected;
    tab.session.statusNotifier.value = ConnectionStatus.connected;
    await settle();
    expect(opens, 1);
  });

  test('a second tab of the same profile does not provision again', () async {
    final a = _tab('a', 'p1');
    final b = _tab('b', 'p1');
    prov().track([a, b]);
    a.session.statusNotifier.value = ConnectionStatus.connected;
    b.session.statusNotifier.value = ConnectionStatus.connected;
    await settle();
    expect(opens, 1);
  });

  test('another profile provisions on its own', () async {
    final a = _tab('a', 'p1');
    final b = _tab('b', 'p2');
    prov().track([a, b]);
    a.session.statusNotifier.value = ConnectionStatus.connected;
    b.session.statusNotifier.value = ConnectionStatus.connected;
    await settle();
    expect(opens, 2);
  });

  test('an opener failure is swallowed (type only) and not retried', () async {
    final failing = ProviderContainer(
      overrides: [
        agentdSecureStorageProvider.overrideWithValue(storage),
        agentdSftpOpenerProvider.overrideWithValue((tab) {
          opens++;
          return Future.error(SftpAbortError('boom $_token'));
        }),
      ],
    );
    addTearDown(failing.dispose);
    final tab = _tab('t1', 'p1');
    failing.read(agentdProvisionerProvider.notifier).track([tab]);
    tab.session.statusNotifier.value = ConnectionStatus.connected;
    await settle();
    expect(opens, 1);
    expect(await failing.read(agentdTokenStoreProvider).read('p1'), isNull);
  });

  test(
    'no SFTP service yet (opener returns null) does not mark it done',
    () async {
      var ready = false;
      final lazy = ProviderContainer(
        overrides: [
          agentdSecureStorageProvider.overrideWithValue(storage),
          agentdSftpOpenerProvider.overrideWithValue((tab) {
            if (!ready) return null;
            opens++;
            return Future.value(sftp);
          }),
        ],
      );
      addTearDown(lazy.dispose);
      final tab = _tab('t1', 'p1');
      final p = lazy.read(agentdProvisionerProvider.notifier);
      p.track([tab]);
      tab.session.statusNotifier.value = ConnectionStatus.connected;
      await settle();
      expect(opens, 0);
      ready = true;
      tab.session.statusNotifier.value = ConnectionStatus.disconnected;
      tab.session.statusNotifier.value = ConnectionStatus.connected;
      await settle();
      expect(opens, 1);
    },
  );

  test('a removed tab is no longer listened to', () async {
    final tab = _tab('t1', 'p1');
    prov().track([tab]);
    prov().track([]);
    tab.session.statusNotifier.value = ConnectionStatus.connected;
    await settle();
    expect(opens, 0);
  });
}
