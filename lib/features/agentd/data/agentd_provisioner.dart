import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/agentd/data/agentd_providers.dart';
import 'package:helm/features/agentd/data/agentd_token_store.dart';
import 'package:helm/features/connection/domain/connection_status.dart';
import 'package:helm/features/files/data/sftp_session.dart';
import 'package:helm/features/terminal/domain/terminal_tab.dart';

/// How the provisioner reaches a tab's SFTP session. It must REUSE the
/// session of the tab's `SftpFileService` (never `client.sftp()` again), so
/// the connection's MaxSessions channel budget is untouched. Null when the
/// tab has no SFTP service yet (not an attempt). Overridable in tests.
typedef AgentdSftpOpener = Future<SftpSession>? Function(TerminalTab tab);

final agentdSftpOpenerProvider = Provider<AgentdSftpOpener>(
  (_) =>
      (tab) => tab.session.fileService?.sharedSession(),
);

/// Copies the daemon token from the host once per profile per app run, on
/// the first `connected` tab of a profile that has no stored token.
///
/// State: the profile ids already handled this run. A missing token file
/// (daemon not installed) is silent; failures are logged by type only and
/// never include the token.
class AgentdProvisioner extends Notifier<Set<String>> {
  static final _log = HelmLogger('AgentdProvisioner');

  final _tabs = <String, ({TerminalTab tab, VoidCallback listener})>{};
  final _inFlight = <String>{};

  @override
  Set<String> build() {
    ref.onDispose(() {
      for (final t in _tabs.values) {
        t.tab.session.statusNotifier.removeListener(t.listener);
      }
      _tabs.clear();
    });
    return const {};
  }

  /// Syncs the tracked tabs with [tabs] (call whenever the tab list changes).
  void track(List<TerminalTab> tabs) {
    final ids = {for (final t in tabs) t.id};
    for (final id in _tabs.keys.where((id) => !ids.contains(id)).toList()) {
      final t = _tabs.remove(id)!;
      t.tab.session.statusNotifier.removeListener(t.listener);
    }
    for (final tab in tabs) {
      if (_tabs.containsKey(tab.id)) continue;
      void listener() => _onStatus(tab);
      _tabs[tab.id] = (tab: tab, listener: listener);
      tab.session.statusNotifier.addListener(listener);
      _onStatus(tab);
    }
  }

  void _onStatus(TerminalTab tab) {
    if (tab.session.statusNotifier.value != ConnectionStatus.connected) return;
    unawaited(_provision(tab));
  }

  Future<void> _provision(TerminalTab tab) async {
    final profileId = tab.profile.id;
    if (state.contains(profileId) || !_inFlight.add(profileId)) return;
    try {
      final store = ref.read(agentdTokenStoreProvider);
      final existing = await store.read(profileId);
      if (existing != null && existing.isNotEmpty) {
        _markDone(profileId);
        return;
      }
      final sftp = ref.read(agentdSftpOpenerProvider)(tab);
      if (sftp == null) return; // no SFTP service yet: try on a later connect
      final outcome = await store.provisionFromHost(await sftp, profileId);
      _markDone(profileId);
      if (outcome is TokenProvisionFailed || outcome is TokenInvalid) {
        _log.w('Token provisioning ended with ${outcome.runtimeType}');
      }
    } catch (e) {
      _markDone(profileId);
      _log.w('Token provisioning failed: ${e.runtimeType}');
    } finally {
      _inFlight.remove(profileId);
    }
  }

  void _markDone(String profileId) {
    if (ref.exists(agentdProvisionerProvider)) {
      state = {...state, profileId};
    }
  }
}

final agentdProvisionerProvider =
    NotifierProvider<AgentdProvisioner, Set<String>>(AgentdProvisioner.new);
