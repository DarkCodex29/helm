import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/adapters/herdr_adapter.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/shell_quote.dart';

import '../../../helpers/fake_host_command_runner.dart';

// herdr's CLI has TWO DISTINCT wire contracts, verified against a real
// herdr 0.8.0 binary — do NOT parse one by analogy to the other. (A
// previous, rejected attempt did exactly that for `session list --json`
// and it threw a runtime TypeError against real output — see the apply
// report's D1–D7.)
//
// 1. SOCKET-backed commands (`agent list`) go through herdr's local unix
//    socket and use its schema-confirmed JSON-RPC-style envelope
//    (`herdr api schema --json`, protocol 19, schema_version 1), recorded
//    in full at Engram topic `sdd/host-session-contract/herdr-contract`.
// 2. LOCAL commands (`session list --json`) read the session/config
//    directory directly and do NOT go through that socket envelope at
//    all. Their shape below is captured VERBATIM from a real invocation
//    on a live Ubuntu 24.04 host with no herdr server running — not from
//    the schema, and not by analogy to `agent list`.
//
// CONFIRMED — socket-backed (`agent list`), from the schema:
// - Success envelope: {id, result} — both required.
// - `agent list` result: {type, agents: AgentInfo[]}.
// - Error envelope: {id, error: {code, message}} — code is always present.
// - AgentInfo required fields: terminal_id, agent_status, workspace_id,
//   tab_id, pane_id, focused, revision. `name`/`title` are OPTIONAL — this
//   adapter must not assume either exists.
// - AgentStatus enum (the agent-level rollup): idle, working, blocked,
//   done, unknown (5 values) — matches AgentState exactly.
// - No-server failure: exit code 1, stdout empty (0 bytes), stderr
//   {"id":"cli:agent:list","error":{"code":"server_not_running", ...}}.
//
// CONFIRMED — local (`session list --json`), from a real captured
// invocation with NO server running:
// - Exit code 0 (NOT 1 — this command succeeds regardless of server
//   state, because it reads the session directory, not the socket).
// - Bare `{sessions: [...]}` envelope — there is NO `id` key and NO
//   `result` key.
// - Per-session fields: `default` (bool), `name` (string), `running`
//   (bool), `session_dir` (string), `socket_path` (string). There is NO
//   `status` string field — no `active`/`exited` anywhere.
//
// Also CONFIRMED directly (not inferred by analogy to
// TmuxAdapter/ZellijAdapter's `detect()` pattern): `herdr --version`
// exists and reports `herdr 0.8.0`.
//
// ASSUMED (not independently confirmed against a live server):
// - `herdr session attach <name>` performs attach-or-create; the schema
//   confirms the subcommand exists (per Engram) but not idempotent-create
//   semantics.
const _agentListCommand = 'herdr agent list';
const _sessionListCommand = 'herdr session list --json';
const _detectCommand = 'command -v herdr >/dev/null 2>&1 && herdr --version';

String _agentListSuccess(List<Map<String, Object?>> agents) => jsonEncode({
  'id': 'cli:agent:list',
  'result': {'type': 'agent_list', 'agents': agents},
});

const _agentListNoServer =
    '{"id":"cli:agent:list","error":{"code":"server_not_running",'
    '"message":"no herdr server is running at socket; run `herdr` to '
    'start or attach it"}}';

const _agentListUnrecognizedError =
    '{"id":"cli:agent:list","error":{"code":"internal_error",'
    '"message":"unexpected failure"}}';

/// Verbatim capture: `herdr session list --json` with NO server running,
/// exit code 0. This is the CONFIRMED "no server" shape for herdr's
/// session listing — unlike `agent list`, this command does not fail
/// when no server is running.
const _sessionListNoServerRunning =
    '{"sessions":[{"default":true,"name":"default","running":false,'
    '"session_dir":"/home/deployer/.config/herdr",'
    '"socket_path":"/home/deployer/.config/herdr/herdr.sock"}]}';

const _sessionListEmpty = '{"sessions":[]}';

void main() {
  late FakeHostCommandRunner runner;
  late HerdrAdapter adapter;

  setUp(() {
    runner = FakeHostCommandRunner();
    adapter = HerdrAdapter(runner);
  });

  group('listAgents', () {
    test('reports each agent with its target, label, and state', () async {
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(
          stdout: _agentListSuccess([
            {
              'terminal_id': 't1',
              'agent_status': 'working',
              'workspace_id': 'w1',
              'tab_id': 'tab1',
              'pane_id': 'p1',
              'focused': true,
              'revision': 1,
              'name': 'claude',
            },
            {
              'terminal_id': 't2',
              'agent_status': 'done',
              'workspace_id': 'w1',
              'tab_id': 'tab2',
              'pane_id': 'p2',
              'focused': false,
              'revision': 1,
            },
          ]),
          exitCode: 0,
        ),
      );

      final result = await adapter.listAgents();

      expect(result, isA<MuxAgentsAvailable>());
      expect((result as MuxAgentsAvailable).agents, [
        (target: 't1', label: 'claude', state: AgentState.working),
        (target: 't2', label: 't2', state: AgentState.done),
      ]);
    });

    test('maps every confirmed agent_status string to AgentState', () async {
      const cases = {
        'idle': AgentState.idle,
        'working': AgentState.working,
        'blocked': AgentState.blocked,
        'done': AgentState.done,
        'unknown': AgentState.unknown,
      };
      for (final entry in cases.entries) {
        runner.whenRun(
          _agentListCommand,
          HostCommandResult(
            stdout: _agentListSuccess([
              {
                'terminal_id': 't1',
                'agent_status': entry.key,
                'workspace_id': 'w1',
                'tab_id': 'tab1',
                'pane_id': 'p1',
                'focused': true,
                'revision': 1,
              },
            ]),
            exitCode: 0,
          ),
        );

        final result = await adapter.listAgents();

        expect((result as MuxAgentsAvailable).agents.single.state, entry.value);
      }
    });

    test('falls back to title when name is absent', () async {
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(
          stdout: _agentListSuccess([
            {
              'terminal_id': 't1',
              'agent_status': 'idle',
              'workspace_id': 'w1',
              'tab_id': 'tab1',
              'pane_id': 'p1',
              'focused': true,
              'revision': 1,
              'title': 'my-title',
            },
          ]),
          exitCode: 0,
        ),
      );

      final result = await adapter.listAgents();

      expect((result as MuxAgentsAvailable).agents.single.label, 'my-title');
    });

    test(
      'falls back to terminal_id when neither name nor title is present',
      () async {
        runner.whenRun(
          _agentListCommand,
          HostCommandResult(
            stdout: _agentListSuccess([
              {
                'terminal_id': 't1',
                'agent_status': 'idle',
                'workspace_id': 'w1',
                'tab_id': 'tab1',
                'pane_id': 'p1',
                'focused': true,
                'revision': 1,
              },
            ]),
            exitCode: 0,
          ),
        );

        final result = await adapter.listAgents();

        expect((result as MuxAgentsAvailable).agents.single.label, 't1');
      },
    );

    test('reports a genuinely empty list when the server IS running', () async {
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(stdout: _agentListSuccess(const []), exitCode: 0),
      );

      final result = await adapter.listAgents();

      expect(result, isA<MuxAgentsAvailable>());
      expect((result as MuxAgentsAvailable).agents, isEmpty);
    });

    test(
      'reports a typed server-not-running state, never an empty list, '
      'when the herdr agent-tracking server is down',
      () async {
        runner.whenRun(
          _agentListCommand,
          const HostCommandResult(stderr: _agentListNoServer, exitCode: 1),
        );

        final result = await adapter.listAgents();

        expect(result, isA<MuxAgentServerNotRunning>());
      },
    );

    test(
      'throws instead of silently collapsing an unrecognized error.code '
      'into server-not-running',
      () async {
        runner.whenRun(
          _agentListCommand,
          const HostCommandResult(
            stderr: _agentListUnrecognizedError,
            exitCode: 1,
          ),
        );

        expect(() => adapter.listAgents(), throwsStateError);
      },
    );
  });

  group('agents capability', () {
    test('is non-null — HerdrAdapter supports agent state', () {
      expect(adapter.agents, isNotNull);
    });

    test('a caller resolving agent support gets the live agent surface', () {
      final support = AgentSupport.resolve(adapter);

      expect(support, isA<AgentSupportAvailable>());
    });

    test(
      'advertises agentState and structuredOutput, never agentWait — '
      'waitForAgent is a single-shot check, not a genuine wait',
      () {
        expect(adapter.capabilities, {
          MuxCapability.agentState,
          MuxCapability.structuredOutput,
        });
        expect(
          adapter.capabilities,
          isNot(contains(MuxCapability.agentWait)),
        );
      },
    );
  });

  group('waitForAgent', () {
    test('returns the status when the agent already matches', () async {
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(
          stdout: _agentListSuccess([
            {
              'terminal_id': 't1',
              'agent_status': 'blocked',
              'workspace_id': 'w1',
              'tab_id': 'tab1',
              'pane_id': 'p1',
              'focused': true,
              'revision': 1,
            },
          ]),
          exitCode: 0,
        ),
      );

      final status = await adapter.waitForAgent(
        't1',
        until: {AgentState.blocked, AgentState.done},
      );

      expect(status, (target: 't1', label: 't1', state: AgentState.blocked));
    });

    test(
      'returns null when the agent exists but is not in any requested '
      'state',
      () async {
        runner.whenRun(
          _agentListCommand,
          HostCommandResult(
            stdout: _agentListSuccess([
              {
                'terminal_id': 't1',
                'agent_status': 'working',
                'workspace_id': 'w1',
                'tab_id': 'tab1',
                'pane_id': 'p1',
                'focused': true,
                'revision': 1,
              },
            ]),
            exitCode: 0,
          ),
        );

        final status = await adapter.waitForAgent(
          't1',
          until: {AgentState.blocked},
        );

        expect(status, isNull);
      },
    );

    test('returns null when no agent matches the target', () async {
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(stdout: _agentListSuccess(const []), exitCode: 0),
      );

      final status = await adapter.waitForAgent(
        'missing',
        until: {AgentState.idle},
      );

      expect(status, isNull);
    });

    test(
      'returns null, never throws, when the herdr agent-tracking server '
      'is not running',
      () async {
        runner.whenRun(
          _agentListCommand,
          const HostCommandResult(stderr: _agentListNoServer, exitCode: 1),
        );

        final status = await adapter.waitForAgent(
          't1',
          until: {AgentState.blocked},
        );

        expect(status, isNull);
      },
    );
  });

  group('listSessions', () {
    test(
      'reports the default session as exited when no server is running, '
      'never an empty list',
      () async {
        // CONFIRMED ground truth: `session list --json` with no server
        // running exits 0 and reports the default session with
        // `running: false` — it does NOT fail the way `agent list` does.
        runner.whenRun(
          _sessionListCommand,
          const HostCommandResult(
            stdout: _sessionListNoServerRunning,
            exitCode: 0,
          ),
        );

        final result = await adapter.listSessions();

        expect(result, isA<MuxSessionsAvailable>());
        expect((result as MuxSessionsAvailable).sessions, [
          (name: 'default', state: MuxSessionState.exited),
        ]);
      },
    );

    test(
      'reports a typed failure state, never a crash, when the list '
      'command fails for an unspecified reason',
      () async {
        // No verified failure sample exists for a genuinely non-zero
        // exit here (see the apply report's D2) — this locks in that the
        // fallback is a defined typed state, not a crash.
        runner.whenRun(
          _sessionListCommand,
          const HostCommandResult(stderr: 'unexpected failure', exitCode: 2),
        );

        final result = await adapter.listSessions();

        expect(result, isA<MuxServerNotRunning>());
      },
    );

    test(
      'a genuinely empty session list is reported when the server IS '
      'running and herdr has zero known sessions',
      () async {
        runner.whenRun(
          _sessionListCommand,
          const HostCommandResult(stdout: _sessionListEmpty, exitCode: 0),
        );

        final result = await adapter.listSessions();

        expect(result, isA<MuxSessionsAvailable>());
        expect((result as MuxSessionsAvailable).sessions, isEmpty);
      },
    );

    test(
      'reports each session state from the running boolean, not a '
      'status string',
      () async {
        runner.whenRun(
          _sessionListCommand,
          const HostCommandResult(
            stdout:
                '{"sessions":[{"default":true,"name":"work","running":true,'
                '"session_dir":"/home/deployer/.config/herdr/work",'
                '"socket_path":"/home/deployer/.config/herdr/work.sock"},'
                '{"default":false,"name":"done-work","running":false,'
                '"session_dir":"/home/deployer/.config/herdr/done-work",'
                '"socket_path":"/home/deployer/.config/herdr/done-work.sock"}]}',
            exitCode: 0,
          ),
        );

        final result = await adapter.listSessions();

        expect((result as MuxSessionsAvailable).sessions, [
          (name: 'work', state: MuxSessionState.active),
          (name: 'done-work', state: MuxSessionState.exited),
        ]);
      },
    );
  });

  group('detect', () {
    test(
      'reports installed and the version when the binary is found',
      () async {
        runner.whenRun(
          _detectCommand,
          const HostCommandResult(stdout: 'herdr 0.8.0\n', exitCode: 0),
        );

        final detection = await adapter.detect();

        expect(detection.installed, isTrue);
        expect(detection.absPath, 'herdr');
        expect(detection.version, 'herdr 0.8.0');
      },
    );

    test('reports not installed when the binary is missing', () async {
      runner.whenRun(_detectCommand, const HostCommandResult(exitCode: 1));

      final detection = await adapter.detect();

      expect(detection.installed, isFalse);
      expect(detection.absPath, isNull);
      expect(detection.version, isNull);
    });
  });

  group('hasSession', () {
    test('returns true when the session is present', () async {
      runner.whenRun(
        _sessionListCommand,
        const HostCommandResult(
          stdout:
              '{"sessions":[{"default":true,"name":"work","running":true,'
              '"session_dir":"/home/deployer/.config/herdr/work",'
              '"socket_path":"/home/deployer/.config/herdr/work.sock"}]}',
          exitCode: 0,
        ),
      );

      expect(await adapter.hasSession('work'), isTrue);
    });

    test('returns false when no session by that name is present', () async {
      runner.whenRun(
        _sessionListCommand,
        const HostCommandResult(stdout: _sessionListEmpty, exitCode: 0),
      );

      expect(await adapter.hasSession('missing'), isFalse);
    });

    test(
      'returns false when the list command fails for an unspecified '
      'reason',
      () async {
        runner.whenRun(
          _sessionListCommand,
          const HostCommandResult(stderr: 'unexpected failure', exitCode: 2),
        );

        expect(await adapter.hasSession('work'), isFalse);
      },
    );
  });

  group('attachCommand', () {
    test('uses `session attach` with a quoted session name', () {
      expect(adapter.attachCommand('work'), "herdr session attach 'work'");
    });

    test('uses the resolved absolute path, not a bare binary name', () {
      final resolved = HerdrAdapter(
        runner,
        absPath: '/home/deployer/.local/bin/herdr',
      );

      expect(
        resolved.attachCommand('work'),
        "/home/deployer/.local/bin/herdr session attach 'work'",
      );
    });

    test('single-quotes a session name with a shell command separator', () {
      const name = 'x; rm -rf ~';
      expect(
        adapter.attachCommand(name),
        'herdr session attach ${shellQuote(name)}',
      );
    });

    test('single-quotes a session name with command substitution', () {
      const name = r'$(id)';
      expect(
        adapter.attachCommand(name),
        'herdr session attach ${shellQuote(name)}',
      );
    });

    test('single-quotes a session name with an embedded single quote', () {
      const name = "O'Brien";
      expect(
        adapter.attachCommand(name),
        'herdr session attach ${shellQuote(name)}',
      );
    });

    test('single-quotes a session name with a leading dash', () {
      const name = '-rf';
      expect(
        adapter.attachCommand(name),
        'herdr session attach ${shellQuote(name)}',
      );
    });
  });
}
