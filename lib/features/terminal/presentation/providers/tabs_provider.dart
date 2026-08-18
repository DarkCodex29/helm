import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/host/session_reference.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/shortcuts/domain/project_shortcut.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';
import 'package:uuid/uuid.dart';

final sshServiceProvider = Provider<SSHService>((_) => SSHService());

final sshKeyServiceProvider = Provider<SSHKeyService>((_) => SSHKeyService());

final connectionProfileRepositoryProvider =
    Provider<ConnectionProfileRepository>((_) => ConnectionProfileRepository());

final sessionSnapshotRepoProvider = Provider<SessionSnapshotRepository>(
  (_) => SessionSnapshotRepository(),
);

class TabsState {
  const TabsState({this.tabs = const [], this.activeIndex = 0});

  final List<TerminalTab> tabs;
  final int activeIndex;

  bool get hasTabs => tabs.isNotEmpty;

  TerminalTab? get activeTab =>
      tabs.isEmpty ? null : tabs[activeIndex.clamp(0, tabs.length - 1)];

  TabsState copyWith({List<TerminalTab>? tabs, int? activeIndex}) {
    return TabsState(
      tabs: tabs ?? this.tabs,
      activeIndex: activeIndex ?? this.activeIndex,
    );
  }
}

class TabsNotifier extends Notifier<TabsState> {
  static final _log = HelmLogger('TabsNotifier');
  static const _uuid = Uuid();

  @override
  TabsState build() => const TabsState();

  Future<void> addTab(
    ConnectionProfile profile, {
    String? tmuxSessionName,
  }) async {
    final sshService = ref.read(sshServiceProvider);
    final keyService = ref.read(sshKeyServiceProvider);

    final privateKey = await keyService.getPrivateKey();
    if (privateKey == null) {
      _log.e('No SSH private key found — cannot open tab');
      return;
    }

    final tabCount = state.tabs.length;
    final sessionName =
        tmuxSessionName ?? '${AppConstants.defaultSessionRef}-$tabCount';

    final session = TerminalSession(
      profile: profile,
      sshService: sshService,
      tmuxSessionName: sessionName,
    );

    final tab = TerminalTab(
      id: _uuid.v4(),
      title: profile.name,
      session: session,
      profile: profile,
    );

    final newTabs = [...state.tabs, tab];
    state = state.copyWith(tabs: newTabs, activeIndex: newTabs.length - 1);

    _log.i('Opening tab: ${profile.name}');

    try {
      await session.connect(privateKey);
    } catch (e) {
      _log.e('Tab connection failed for ${profile.name}', e);
    }
  }

  Future<void> removeTab(String id) async {
    final index = state.tabs.indexWhere((t) => t.id == id);
    if (index == -1) return;

    final tab = state.tabs[index];
    await tab.session.dispose();

    final newTabs = [...state.tabs]..removeAt(index);
    final newIndex = newTabs.isEmpty
        ? 0
        : (index >= newTabs.length ? newTabs.length - 1 : index);

    state = state.copyWith(tabs: newTabs, activeIndex: newIndex);
    _log.i('Closed tab: ${tab.profile.name}');
  }

  void setActiveTab(int index) {
    if (index < 0 || index >= state.tabs.length) return;
    state = state.copyWith(activeIndex: index);
  }

  Future<List<ConnectionProfile>> loadProfiles() async {
    return ref.read(connectionProfileRepositoryProvider).getAll();
  }

  /// Persiste el snapshot de la sesión actual al storage.
  ///
  /// Llamado por [HomeScreen] cuando la app pasa a `paused` (background).
  /// Si no hay tabs abiertas → limpia el snapshot.
  /// Si hay tabs → guarda snapshot + timestamp para detección de crash.
  Future<void> saveSnapshot() async {
    final repo = ref.read(sessionSnapshotRepoProvider);
    if (state.tabs.isEmpty) {
      await repo.markClean();
    } else {
      final snapshots = state.tabs.map((t) {
        final idx = state.tabs.indexWhere((x) => x.id == t.id);
        final resolvedSessionName =
            t.session.tmuxSessionName ??
            t.profile.sessionRef ??
            t.profile.tmuxSession ??
            '${AppConstants.defaultSessionRef}-$idx';
        // Mirror the resolved value into both fields — see
        // lib/core/host/session_reference.dart for why this must be the
        // sole mirroring point rather than re-derived here.
        final mirrored = mirrorSessionReference(resolvedSessionName);
        return TabSnapshot(
          profileId: t.profile.id,
          profileName: t.profile.name,
          tmuxSessionName: mirrored.legacyValue,
          sessionRef: mirrored.sessionRef,
          multiplexer: t.profile.multiplexer,
        );
      }).toList();
      await repo.markDirty(snapshots);
    }
  }

  /// Reconecta todas las tabs guardadas en un snapshot de crash.
  Future<void> recoverSession(List<TabSnapshot> snapshots) async {
    final repo = ref.read(sessionSnapshotRepoProvider);
    final profileRepo = ref.read(connectionProfileRepositoryProvider);

    for (final snap in snapshots) {
      ConnectionProfile? profile = await profileRepo.getById(snap.profileId);
      profile ??= await profileRepo.getDefault();

      if (profile == null) {
        _log.w('No profile found for recovery snap: ${snap.profileId}');
        continue;
      }

      await addTab(
        profile,
        tmuxSessionName: snap.sessionRef ?? snap.tmuxSessionName,
      );
    }

    await repo.markClean();
  }

  /// Opens a tab for the given [shortcut], navigates to its project path,
  /// and optionally runs a command.
  Future<void> openShortcut(ProjectShortcut shortcut) async {
    final repo = ref.read(connectionProfileRepositoryProvider);

    // Find the profile by ID, fall back to default.
    ConnectionProfile? profile = await repo.getById(shortcut.profileId);
    profile ??= await repo.getDefault();

    if (profile == null) {
      _log.w('No profile found for shortcut ${shortcut.name}');
      return;
    }

    await addTab(
      profile,
      tmuxSessionName: shortcut.sessionRef ?? shortcut.tmuxSession,
    );

    // Wait for tmux to be ready before sending commands.
    await Future.delayed(const Duration(milliseconds: 500));

    final session = state.activeTab?.session;
    if (session == null || !session.isConnected) return;

    // Navigate to project path.
    final cmd = shortcut.command.isNotEmpty
        ? 'cd ${shortcut.projectPath} && ${shortcut.command}\n'
        : 'cd ${shortcut.projectPath}\n';

    session.terminal.onOutput?.call(cmd);
    _log.i('Opened shortcut: ${shortcut.name} → $cmd');
  }
}

final tabsProvider = NotifierProvider<TabsNotifier, TabsState>(
  TabsNotifier.new,
);
