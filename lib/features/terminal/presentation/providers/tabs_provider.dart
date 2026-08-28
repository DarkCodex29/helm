import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/host/session_reference.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/notifications/presentation/push_notification_provider.dart';
import 'package:helm/features/session_hold/domain/auto_hold_request.dart';
import 'package:helm/features/session_hold/presentation/session_hold_provider.dart';
import 'package:helm/features/shortcuts/domain/project_shortcut.dart';
import 'package:helm/features/terminal/data/session_snapshot_repository.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';
import 'package:helm/features/terminal/domain/auto_connect_decision.dart';
import 'package:helm/features/terminal/domain/session_name.dart';
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

  /// Suffix for a session nobody named.
  ///
  /// The first block of a v4 UUID: eight hex characters, short enough to
  /// stay readable in `herdr session list` and in the tab title bar.
  ///
  /// Random rather than sequential, and that is the point. A counter is
  /// what produced `[helm-1, helm-1]`, and a counter also RESETS when the
  /// app does while herdr sessions do not — `helm-0`, `helm-1` and
  /// `helm-2` were all still running on the verified host from earlier
  /// launches, so a fresh counter would silently reattach to one of them.
  /// [resolveSessionName] still checks the result against the names in
  /// use, so uniqueness is structural rather than probabilistic.
  static String _mintSessionSuffix() => _uuid.v4().split('-').first;

  /// Opens a tab for [profile], or focuses the one already holding the
  /// session it resolves to.
  ///
  /// [tmuxSessionName] names a specific session and outranks the profile.
  /// Crash recovery and project shortcuts both use it — see
  /// [resolveSessionName] for the full precedence and for why a positional
  /// counter is not an option.
  Future<void> addTab(
    ConnectionProfile profile, {
    String? tmuxSessionName,
  }) async {
    // Resolved BEFORE the key lookup, so focusing an already-open session
    // costs nothing and cannot be turned into a silent no-op by a missing
    // key — the tab the user is asking for is right there either way.
    final resolution = resolveSessionName(
      profile: profile,
      requestedSessionName: tmuxSessionName,
      openTabs: [
        for (final t in state.tabs)
          (tabId: t.id, sessionName: t.session.tmuxSessionName),
      ],
      mintSuffix: _mintSessionSuffix,
    );

    switch (resolution) {
      case FocusOpenTab(:final tabId, :final sessionName):
        // Two tabs on one herdr session render the same screen and, since
        // 62565f3, each resizes that shared remote PTY to its own
        // viewport. Showing the tab that already has it is the honest
        // answer to "open this session" when it is already open.
        final index = state.tabs.indexWhere((t) => t.id == tabId);
        if (index != -1) {
          _log.i('Session $sessionName is already open — focusing its tab');
          state = state.copyWith(activeIndex: index);
          return;
        }
      case OpenSession():
        break;
    }

    final sessionName = (resolution as OpenSession).sessionName;

    final sshService = ref.read(sshServiceProvider);
    final keyService = ref.read(sshKeyServiceProvider);

    final privateKey = await keyService.getPrivateKey();
    if (privateKey == null) {
      _log.e('No SSH private key found — cannot open tab');
      return;
    }

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

    // Adding a tab makes it the ACTIVE tab, which is precisely the promise
    // that a HelmTerminalView is about to render this session. Announcing
    // it here — before dialing — is what lets connect() wait for the real
    // viewport instead of opening the remote PTY at xterm's 80x24 default.
    //
    // It has to be said HERE and not only in the view's initState: the
    // state assignment below merely schedules a rebuild, so the view does
    // not exist yet at the moment connect() is called. That gap is the
    // whole reason the remote used to paint wider than the screen.
    session.attachViewport();

    final newTabs = [...state.tabs, tab];
    state = state.copyWith(tabs: newTabs, activeIndex: newTabs.length - 1);

    _log.i('Opening tab: ${profile.name}');

    try {
      await session.connect(privateKey);
      _registerForPushNotifications(session);
      await _holdIfTheProfileAsked(profile, session);
    } catch (e) {
      _log.e('Tab connection failed for ${profile.name}', e);
    }
  }

  /// Honors the profile editor's background-hold switch.
  ///
  /// ### Why here, and only here
  ///
  /// This is the single line every way of opening a session runs through
  /// — launch auto-connect, crash recovery, a push notification, a
  /// project shortcut and the new-tab sheet all reach the host through
  /// [addTab]. Putting the rule anywhere else would mean re-deriving it
  /// per entry point, and one of them would eventually disagree.
  ///
  /// ### Why AFTER the connect, inside the try
  ///
  /// A foreground service over a connection that was never established is
  /// a notification about nothing, and Play reads that as exactly the
  /// abuse the perceptibility rule exists to stop. `connect` throws on
  /// failure, so a failed dial skips this for free rather than by a flag
  /// somebody has to remember to check.
  ///
  /// ### Why it is awaited
  ///
  /// It resolves as fast as a binder call into this app's own process,
  /// and it cannot throw anything new at the caller: it sits inside the
  /// same `catch` that already absorbs a failed connect, and
  /// `PlatformForegroundServiceHost.start` turns a platform refusal into
  /// `false` rather than an exception. Awaiting buys a deterministic
  /// ordering — the tab is open and held, or open and not — instead of a
  /// hold that lands a frame or two after whatever asked for the tab has
  /// already returned.
  Future<void> _holdIfTheProfileAsked(
    ConnectionProfile profile,
    TerminalSession session,
  ) async {
    final request = autoHoldRequest(
      profileHoldsInBackground: profile.holdInBackground,
      multiplexerSessionName: session.tmuxSessionName,
      profileName: profile.name,
      status: session.statusNotifier,
    );
    if (request == null) return;

    await ref.read(sessionHoldControllerProvider).holdOnConnect(request);
  }

  /// Tells the host which device to push to, over the connection just
  /// opened.
  ///
  /// Gated on [TerminalSession.tracksAgents] rather than on "connected":
  /// a session with no multiplexer attached can never produce an agent
  /// alert, so asking for a notification permission there would spend one
  /// of Android's few prompts on a capability this host does not have.
  ///
  /// NOT awaited, deliberately. This runs on the path that opens a tab,
  /// and the user is waiting for a terminal, not for a notification
  /// registration. Nothing inside can throw — every failure is folded
  /// into a `TokenRegistrationOutcome` — so an unawaited future here
  /// cannot surface as an unhandled async error either.
  void _registerForPushNotifications(TerminalSession session) {
    if (!session.tracksAgents) return;
    final runner = session.hostRunner;
    if (runner == null) return;

    unawaited(
      ref
          .read(pushNotificationServiceProvider)
          .onAgentTrackingStarted(runner),
    );
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

  /// Honors the profile editor's "Opens automatically on launch" promise.
  ///
  /// Opens at most ONE session, for the profile the user explicitly marked
  /// default, and only when [decideAutoConnect] says so — see that
  /// function for every rule and the reasoning behind each.
  ///
  /// [recoveryPending] must be the ALREADY-RESOLVED answer to "is a crash
  /// snapshot waiting on the user", not a future to be awaited here. The
  /// caller reads it first and hands it in, so auto-connect can never race
  /// the recovery offer it is supposed to defer to.
  ///
  /// DEGRADES QUIETLY, BY CONSTRUCTION. Nothing below can throw at the
  /// caller: [addTab] adds its tab to state BEFORE dialing and swallows a
  /// failed connect, so an unreachable host, a refused auth or a missing
  /// key leaves Home rendered and usable with the failure shown inside the
  /// tab — the terminal carries `[Helm] Connection failed: …`, the tab's
  /// status dot goes red, and any host advisories publish as usual. No
  /// modal, no blocking spinner: the tab exists from the first frame, in
  /// `connecting`, and the connect attempt is bounded by the SSH client's
  /// own 15-second socket timeout rather than hanging forever.
  ///
  /// Returns the decision so a caller can log or surface which rule
  /// applied; every [AutoConnectSkip] is a normal outcome, never an error.
  Future<AutoConnectDecision> autoConnectDefault({
    required bool recoveryPending,
  }) async {
    final profiles = await ref.read(connectionProfileRepositoryProvider).getAll();

    final decision = decideAutoConnect(
      profiles: profiles,
      openProfileIds: state.tabs.map((t) => t.profile.id).toList(),
      recoveryPending: recoveryPending,
    );

    switch (decision) {
      case AutoConnectStart(:final profile):
        _log.i('Auto-connecting default profile: ${profile.name}');
        await addTab(profile);
      case AutoConnectSkip(:final reason):
        _log.i('Auto-connect skipped: ${reason.name}');
    }

    return decision;
  }

  /// Persists a snapshot of the current session to storage.
  ///
  /// Called by [HomeScreen] when the app goes `paused` (backgrounded).
  /// No open tabs -> clears the snapshot.
  /// Open tabs -> stores snapshot + timestamp for crash detection.
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

  /// Opens the session a push notification asked for.
  ///
  /// [sessionName] is the herdr/tmux session name from the notification's
  /// `session` key — see [SessionAlert] for the full wire contract.
  ///
  /// ### Why no profile comes over the wire
  ///
  /// The notifier runs on the Mac and knows nothing about helm's
  /// connection profiles: they are phone-side records with phone-minted
  /// UUIDs. Asking it to name one would make the payload depend on state
  /// the sender cannot see, and would break the moment a profile was
  /// edited. Resolution is this side's job, and it is cheap: a session
  /// already open is focused wherever it lives, and otherwise the default
  /// profile is dialled — the same profile launch would have used.
  ///
  /// ### Why it goes through [addTab]
  ///
  /// [resolveSessionName] already decides whether a name means "attach"
  /// or "focus the tab that has it", and two tabs on one session render
  /// the same screen while fighting over the remote PTY size. Routing the
  /// notification through the same door means that rule cannot be
  /// bypassed by this path.
  ///
  /// DEGRADES QUIETLY. No profile, or a name that survived a malformed
  /// payload as empty, leaves Home exactly as it was.
  Future<void> openSessionNamed(String sessionName) async {
    if (sessionName.isEmpty) {
      _log.w('Notification named no session; leaving Home as it is');
      return;
    }

    final repo = ref.read(connectionProfileRepositoryProvider);
    final profile = await repo.getDefault();
    if (profile == null) {
      _log.w('No profile to open notification session $sessionName with');
      return;
    }

    _log.i('Opening session $sessionName from a notification');
    await addTab(profile, tmuxSessionName: sessionName);
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
