import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';
import 'package:uuid/uuid.dart';

final sshServiceProvider = Provider<SSHService>((_) => SSHService());

final sshKeyServiceProvider = Provider<SSHKeyService>((_) => SSHKeyService());

final connectionProfileRepositoryProvider =
    Provider<ConnectionProfileRepository>((_) => ConnectionProfileRepository());

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
        tmuxSessionName ?? '${AppConstants.defaultTmuxSession}-$tabCount';

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

  Future<void> openDefaultTab() async {
    final repo = ref.read(connectionProfileRepositoryProvider);
    final profile = await repo.getDefault();
    if (profile == null) {
      _log.w('No default profile found — cannot auto-open tab');
      return;
    }
    await addTab(profile);
  }
}

final tabsProvider = NotifierProvider<TabsNotifier, TabsState>(
  TabsNotifier.new,
);
