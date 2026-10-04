// `addTab` must open the session the user asked for, and never two tabs
// on one.
//
// Reproduced against the running app before this landed:
//
//   * [helm-0, helm-1] -> close helm-0 -> new tab -> [helm-1, helm-1].
//     Two tabs attached to ONE herdr session; since 62565f3 each also
//     resizes that shared remote PTY to its own viewport.
//   * a profile with sessionRef "my-work" opened "helm-0". The profile
//     editor persists and reloads that field, and nothing read it.
//
// The naming rule itself is unit-tested in
// `test/features/terminal/domain/session_name_test.dart`. What is pinned
// here is that `addTab` actually applies it — including the paths that
// were already passing an explicit name, so crash recovery and shortcuts
// are proven not to regress.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../helpers/fake_secure_storage.dart';
import '../../../../helpers/fake_ssh_service.dart';

const _plain = ConnectionProfile(
  id: 'p-plain',
  name: 'VPS',
  host: '158.220.106.131',
  username: 'deployer',
  isDefault: true,
);

const _named = ConnectionProfile(
  id: 'p-named',
  name: 'VPS Work',
  host: '158.220.106.131',
  username: 'deployer',
  sessionRef: 'my-work',
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

/// Opens a tab and releases the viewport wait so `addTab` completes.
Future<void> _open(
  ProviderContainer c,
  ConnectionProfile profile, {
  String? sessionName,
}) async {
  final opening = c
      .read(tabsProvider.notifier)
      .addTab(profile, tmuxSessionName: sessionName);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  for (final t in c.read(tabsProvider).tabs) {
    t.session.onResize(51, 29);
  }
  await opening;
}

List<String?> _names(ProviderContainer c) => c
    .read(tabsProvider)
    .tabs
    .map((t) => t.session.tmuxSessionName)
    .toList();

void main() {
  late FakeSSHService ssh;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppConstants.profilesStorageKey: [
        jsonEncode(_plain.toJson()),
        jsonEncode(_named.toJson()),
      ],
    });
    ssh = FakeSSHService();
    container = _container(ssh);
  });

  tearDown(() => container.dispose());

  group("the profile's session reference is opened", () {
    test('a profile with sessionRef attaches to THAT session', () async {
      await _open(container, _named);

      expect(_names(container), ['my-work']);
    });

    test('a profile without one gets a generated helm- name', () async {
      await _open(container, _plain);

      expect(_names(container).single, startsWith('helm-'));
    });

    test('the generated name is not the tab index', () async {
      // 'helm-0' was the old answer for the first tab. Matching it now
      // would mean the counter survived under a new name.
      await _open(container, _plain);

      expect(_names(container).single, isNot('helm-0'));
    });
  });

  group('two tabs never collide on one session', () {
    test(
      'the reported sequence - open, open, close the first, open - no '
      'longer duplicates a name',
      () async {
        await _open(container, _plain);
        await _open(container, _plain);
        expect(_names(container), hasLength(2));

        final first = container.read(tabsProvider).tabs.first;
        await container.read(tabsProvider.notifier).removeTab(first.id);

        await _open(container, _plain);

        final names = _names(container);
        expect(names, hasLength(2));
        expect(
          names.toSet(),
          hasLength(2),
          reason: 'two tabs attached to the same herdr session',
        );
      },
    );

    test('many opens and closes never repeat a live name', () async {
      for (var i = 0; i < 4; i++) {
        await _open(container, _plain);
      }
      final tabs = container.read(tabsProvider).tabs;
      await container.read(tabsProvider.notifier).removeTab(tabs[0].id);
      await container.read(tabsProvider.notifier).removeTab(tabs[2].id);
      await _open(container, _plain);
      await _open(container, _plain);

      final names = _names(container);
      expect(names.toSet(), hasLength(names.length));
    });

    test(
      'opening a NAMED profile that is already open focuses its tab '
      'instead of dialing again',
      () async {
        await _open(container, _named);
        final dialsAfterFirst = ssh.connectCalls.length;

        await _open(container, _named);

        expect(
          container.read(tabsProvider).tabs,
          hasLength(1),
          reason: 'a second tab on one herdr session is the defect',
        );
        expect(
          ssh.connectCalls.length,
          dialsAfterFirst,
          reason: 'focusing an open tab must not open a second connection',
        );
      },
    );

    test('focusing makes that tab the active one', () async {
      await _open(container, _named);
      await _open(container, _plain);
      expect(container.read(tabsProvider).activeIndex, 1);

      await _open(container, _named);

      expect(container.read(tabsProvider).activeIndex, 0);
    });

    test(
      'opening an UNNAMED profile twice DOES give a second session',
      () async {
        // The documented counterpart: a profile that names no session has
        // not claimed there is only one, so a second tab is a second
        // shell — with a session of its own.
        await _open(container, _plain);
        await _open(container, _plain);

        final names = _names(container);
        expect(names, hasLength(2));
        expect(names.toSet(), hasLength(2));
      },
    );
  });

  group('explicit names still work', () {
    test('crash recovery reattaches to the snapshotted session', () async {
      await container.read(tabsProvider.notifier).recoverSession(const [
        TabSnapshot(
          profileId: 'p-plain',
          profileName: 'VPS',
          tmuxSessionName: 'helm-2',
          sessionRef: 'helm-2',
        ),
      ]);
      for (final t in container.read(tabsProvider).tabs) {
        t.session.onResize(51, 29);
      }
      await Future<void>.delayed(Duration.zero);

      expect(_names(container), ['helm-2']);
    });

    test(
      'recovery beats the profile - the snapshot names the session that '
      'was actually running',
      () async {
        await container.read(tabsProvider.notifier).recoverSession(const [
          TabSnapshot(
            profileId: 'p-named',
            profileName: 'VPS Work',
            tmuxSessionName: 'helm-9',
            sessionRef: 'helm-9',
          ),
        ]);
        for (final t in container.read(tabsProvider).tabs) {
          t.session.onResize(51, 29);
        }
        await Future<void>.delayed(Duration.zero);

        expect(_names(container), ['helm-9']);
      },
    );

    test('an explicit name is honored over a generated one', () async {
      await _open(container, _plain, sessionName: 'metalpren');

      expect(_names(container), ['metalpren']);
    });
  });

  group('the snapshot records the session that is actually attached', () {
    // Read back from storage rather than through getPendingRecovery(),
    // which deliberately ignores a snapshot younger than its crash
    // threshold — a real guard against fast pause/resume, and not what
    // these two are about.
    Future<List<TabSnapshot>> storedSnapshots() async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppConstants.sessionSnapshotKey)!;
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => TabSnapshot.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    test("a named profile's snapshot carries its session reference", () async {
      // saveSnapshot's fallback chain starts at session.tmuxSessionName,
      // which used to be the positional name — so recovery re-pinned that
      // and the profile's own value stayed unreachable. Now the session
      // IS the profile's value, and the snapshot inherits it.
      await _open(container, _named);
      await container.read(tabsProvider.notifier).saveSnapshot();

      final stored = await storedSnapshots();

      expect(stored.single.sessionRef, 'my-work');
      expect(stored.single.tmuxSessionName, 'my-work');
    });

    test('a generated name round-trips through the snapshot', () async {
      await _open(container, _plain);
      final live = _names(container).single;
      await container.read(tabsProvider.notifier).saveSnapshot();

      final stored = await storedSnapshots();

      expect(stored.single.sessionRef, live);
      expect(stored.single.tmuxSessionName, live);
    });

    test('recovering that snapshot reopens the SAME session', () async {
      // End to end: the name a tab is using survives a snapshot and comes
      // back attached to the same herdr session, which is the only thing
      // crash recovery is for.
      await _open(container, _named);
      await container.read(tabsProvider.notifier).saveSnapshot();
      final stored = await storedSnapshots();

      await container.read(tabsProvider.notifier).removeTab(
            container.read(tabsProvider).tabs.single.id,
          );
      expect(container.read(tabsProvider).tabs, isEmpty);

      await container.read(tabsProvider.notifier).recoverSession(stored);
      for (final t in container.read(tabsProvider).tabs) {
        t.session.onResize(51, 29);
      }
      await Future<void>.delayed(Duration.zero);

      expect(_names(container), ['my-work']);
    });
  });
}
