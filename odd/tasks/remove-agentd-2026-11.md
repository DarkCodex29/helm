# remove-agentd-2026-11

Remove `helm-agentd` and everything that only exists for it. helm stays a
terminal into the Mac; the Mac already runs the agents.

## Specs

- **S1** — User, after the physical validation showed the daemon runs its
  own Pi apart from the herdr tabs: "el punto 1 no es conectar, ya que mi
  mac tienen todo, y nosotros en si , solo necesitamos una terminal y
  listo". Asked what to do with `helm-agentd`, the user chose "Quitarlo del
  todo (recomendado)": disable the LaunchAgent, remove the agentd client,
  the badge and the banner from the app, and delete the package and the
  installer. helm stays as terminal + notifier.
- **S2** — Keep working everything that does not come from agentd: the
  herdr agent state in the tab bar (`agentsNotifier`, the herdr badge),
  the notifier in `host/notifier/` and its per-device ntfy/FCM
  registration, the T5 split of `terminal_session.dart`, and the SFTP file
  features.
- **S3** — Every change keeps `flutter analyze`, `flutter test`, `dart
  format` and the remaining CI jobs green; CI drops the jobs that only
  served agentd.
- **S4** — Public repository: no tailnet name, host, token or owner path
  in code, docs or test output.

## Tasks

| ID | Specs | Task | Route | Commit |
|---|---|---|---|---|
| T1 | S1, S4 | Disable the agentd LaunchAgent on the Mac; close port 7480 | parent | n/a (host) |
| T2 | S1-S4 | Remove agentd from the app, `packages/helm_agentd`, `packages/helm_protocol`, `host/agentd`, CI and docs; keep S2 working | worker | uncommitted |
| T3 | S3 | Verify, push to main, watch CI | parent + verify | |
| T4 | S2 | Rebuild `--release` on the iPhone; smoke-check the terminal | parent | |

## Log

- **L1** (2026-11-07) — User: "dale, y el punto 1 no es conectar, ya que
  mi mac tienen todo, y nosotros en si , solo necesitamos una terminal y
  listo, no se si te habras dado cuenta de eso". Then chose "Quitarlo del
  todo (recomendado)".
- **L2** — T1 done by the parent: `launchctl bootout` of
  `dev.helm.agentd` (no listener on 7480 afterwards); the plist and
  `~/.helm-agentd` moved to `~/.Trash` (a plain recursive delete was
  blocked by the safety guard). `dev.helm.notifier` still running.
- **L3** — T2 done by the worker (uncommitted). Removed: `lib/features/agentd`,
  `test/features/agentd`, `packages/helm_agentd`, `packages/helm_protocol`,
  `host/agentd`, `agent_ask_banner.dart` and its test,
  `home_screen_agent_ask_test.dart`; `AgentdBadge`/`AgentdHint`,
  `AgentAskSemantics`, the banner slot and the token provisioning hook in
  `home_screen.dart`, `SftpFileService.sharedSession` (only the provisioner used
  it), the pubspec entries, the CI jobs `helm_protocol`, `helm_agentd`,
  `agentd_installer` plus their nested pub-get/format steps, and the agentd
  sections of README and `docs/HOST_SETUP.md`. Kept (S2): herdr badge via
  `agentsNotifier` with the listener mounted (`tab_bar_agent_arming_test` keeps
  its herdr assertions; only the agentd-badge test was dropped), notifier,
  TerminalSession, SFTP files. Checks: `flutter pub get` ok; `dart format
  --output=none --set-exit-if-changed lib test` clean (270 files); `flutter
  analyze` no issues; `flutter test` +1659 all passed;
  `rg -i 'agentd|helm_protocol|7480'` outside `odd/`: no matches.
