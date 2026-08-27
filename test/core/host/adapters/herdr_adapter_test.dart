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
const _paneListCommand = 'herdr pane list';
const _detectCommand = 'command -v herdr >/dev/null 2>&1 && herdr --version';

String _paneListSuccess(List<Map<String, Object?>> panes) => jsonEncode({
  'id': 'cli:pane:list',
  'result': {'panes': panes, 'type': 'pane_list'},
});

/// One `pane list` entry in the exact shape a RESURRECTED-EMPTY session
/// reported on the real host — including the fields helm does not read.
/// The three that matter: `revision` is 1 (never touched), `cwd` is $HOME,
/// and `agent_status` is "unknown".
const _virginPaneInfo = {
  'agent_status': 'unknown',
  'cwd': '/home/deployer',
  'focused': true,
  'foreground_cwd': '/home/deployer',
  'pane_id': 'w1:p1',
  'revision': 1,
  'scroll': {'offset': 0, 'viewport': 24},
  'tab_id': 'w1:t1',
  'terminal_id': 'term_659ab3dc3a8541',
  'terminal_title': 'deployer@vmi2862525: ~',
  'terminal_title_stripped': 'deployer@vmi2862525: ~',
  'workspace_id': 'w1',
};

/// `pane list` is socket-backed, so it fails exactly the way `agent list`
/// does when no server is up.
const _paneListNoServer =
    '{"id":"cli:pane:list","error":{"code":"server_not_running",'
    '"message":"no herdr server is running at socket; run `herdr` to '
    'start or attach it"}}';

String _agentListSuccess(List<Map<String, Object?>> agents) => jsonEncode({
  'id': 'cli:agent:list',
  'result': {'type': 'agent_list', 'agents': agents},
});

const _agentListNoServer =
    '{"id":"cli:agent:list","error":{"code":"server_not_running",'
    '"message":"no herdr server is running at socket; run `herdr` to '
    'start or attach it"}}';

/// One `AgentInfo`, captured VERBATIM from a live `herdr --session helm-0
/// agent list` on a real host — including the fields helm does not read.
/// Note what is ABSENT: neither `name` nor `title` is present. `agent`
/// ("claude") is what a real host actually offers as a readable name, and
/// it is what `label` resolves to here — see the `reads the agent field`
/// test for why the chain must not stop before it.
const _blockedAgentInfo = {
  'agent': 'claude',
  'agent_status': 'blocked',
  'cwd': '/home/deployer',
  'focused': true,
  'foreground_cwd': '/home/deployer',
  'pane_id': 'w1:p1',
  'revision': 1,
  'state_change_seq': 8,
  'tab_id': 'w1:t1',
  'terminal_id': 'term_659ab3dc3a8541',
  'terminal_title': 'deployer@vmi2862525: ~',
  'terminal_title_stripped': 'deployer@vmi2862525: ~',
  'workspace_id': 'w1',
};

/// `agent wait`'s success envelope: `{id, result: {agent, type}}` — one
/// AGENT, not the `agents` LIST `agent list` returns. Captured verbatim.
String _agentWaitSuccess(Map<String, Object?> agent) => jsonEncode({
  'id': 'cli:agent:wait',
  'result': {'agent': agent, 'type': 'agent_info'},
});

/// Verbatim, exit code 1, on stderr.
const _agentWaitTimeout =
    '{"error":{"code":"timeout","message":"timed out waiting for agent '
    'status"},"id":"cli:agent:wait"}';

/// Verbatim, exit code 1, on stderr — what the OLD terminal-id target
/// produced on every single call.
const _agentWaitNotFound =
    '{"error":{"code":"agent_not_found","message":"agent target '
    'term_659ab3dc3a8541 not found"},"id":"cli:agent:wait"}';

const _agentWaitNoServer =
    '{"id":"cli:agent:wait","error":{"code":"server_not_running",'
    '"message":"no herdr server is running at socket"}}';

/// `agent focus`'s success envelope, captured VERBATIM from a live
/// `herdr agent focus w1:p1` against a real herdr 0.8.2.
///
/// It answers with the FOCUSED agent, in the same `{id, result: {agent,
/// type: "agent_info"}}` shape `agent wait` uses — NOT an empty result and
/// NOT the `agents` list `agent list` returns. The adapter deliberately
/// does not parse it (see [MuxAgentFocused]), so this fixture exists to
/// prove the success path is decided by the EXIT CODE and cannot be broken
/// by a body nobody reads.
String _agentFocusSuccess(Map<String, Object?> agent) => jsonEncode({
  'id': 'cli:agent:focus',
  'result': {'agent': agent, 'type': 'agent_info'},
});

/// Verbatim, exit code 1, on STDERR — measured against herdr 0.8.2 with
/// `herdr agent focus w99:p99`. Confirmed to go to stderr and not stdout:
/// `herdr agent focus w99:p99 2>/dev/null` prints nothing.
const _agentFocusNotFound =
    '{"error":{"code":"agent_not_found","message":"agent target w99:p99 '
    'not found"},"id":"cli:agent:focus"}';

/// Verbatim, exit code 1, on stderr — measured with
/// `herdr --session helm-does-not-exist agent focus w1:p1`.
const _agentFocusNoServer =
    '{"id":"cli:agent:focus","error":{"code":"server_not_running",'
    '"message":"no herdr server is running at '
    '/home/deployer/.config/herdr/sessions/helm-0/herdr.sock; run `herdr '
    'session attach helm-0` to start or attach it"}}';

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
        // `target` is the PANE id — see the dedicated regression test
        // below. The second agent carries no `name`, `title` or `agent`,
        // so its `label` falls all the way through to the TERMINAL id,
        // which is the only one of the four the schema guarantees.
        (
          target: 'p1',
          label: 'claude',
          state: AgentState.working,
          tabId: 'tab1',
          workspaceId: 'w1',
        ),
        (
          target: 'p2',
          label: 't2',
          state: AgentState.done,
          tabId: 'tab2',
          workspaceId: 'w1',
        ),
      ]);
    });

    test('reports the PANE id as the target, never the terminal id — the '
        'pane id is the only identifier herdr agent wait accepts', () async {
      // MEASURED against herdr 0.8.0, both spellings, same agent:
      //   agent wait w1:p1                 → blocks, then returns the agent
      //   agent wait term_659ab3dc3a8541   → {"error":{"code":
      //                                       "agent_not_found", ...}}
      // A target carrying the terminal id is therefore not a target at
      // all: every wait built from it fails with agent_not_found. This
      // pins the identifier at the parse, which is where the defect was.
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(
          stdout: _agentListSuccess([
            {
              'terminal_id': 'term_659ab3dc3a8541',
              'agent_status': 'blocked',
              'workspace_id': 'w1',
              'tab_id': 'w1:t1',
              'pane_id': 'w1:p1',
              'focused': true,
              'revision': 1,
            },
          ]),
          exitCode: 0,
        ),
      );

      final result = await adapter.listAgents();

      final agent = (result as MuxAgentsAvailable).agents.single;
      expect(agent.target, 'w1:p1');
      expect(agent.target, isNot('term_659ab3dc3a8541'));
    });

    test('reads the tab and workspace the agent sits in straight off the '
        'wire, rather than deriving them from the pane id', () async {
      // MEASURED against the owner's live herdr 0.8.2: every entry of
      // `agent list` carries `tab_id` and `workspace_id` as their own
      // fields, beside `pane_id`. The ids also happen to share a visible
      // shape — `w1:p1` sat in `w1:t1` — but that convention is NOT what
      // this reads, because it is a convention and these are facts.
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(
          stdout: _agentListSuccess([
            {
              'terminal_id': 'term_65a07c99f57a51',
              'agent_status': 'working',
              'workspace_id': 'w1',
              'tab_id': 'w1:t1',
              'pane_id': 'w1:p1',
              'focused': false,
              'revision': 26,
              'name': 'opencode',
            },
          ]),
          exitCode: 0,
        ),
      );

      final agent =
          (await adapter.listAgents() as MuxAgentsAvailable).agents.single;

      expect(agent.tabId, 'w1:t1');
      expect(agent.workspaceId, 'w1');
    });

    test('an agent whose entry omits tab_id or workspace_id still parses, and '
        'reports the absence rather than taking the whole list down', () async {
      // The schema guarantees `terminal_id` and nothing else — the rule
      // the label fallback above already follows. A hard cast here would
      // throw inside the parse and turn EVERY agent into an unreachable
      // server, which is a much larger lie than one row without context.
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(
          stdout: _agentListSuccess([
            {
              'terminal_id': 't1',
              'agent_status': 'idle',
              'pane_id': 'p1',
              'focused': false,
              'revision': 1,
              'name': 'opencode',
            },
          ]),
          exitCode: 0,
        ),
      );

      final result = await adapter.listAgents();

      expect(result, isA<MuxAgentsAvailable>());
      final agent = (result as MuxAgentsAvailable).agents.single;
      expect(agent.label, 'opencode');
      expect(agent.tabId, isNull);
      expect(agent.workspaceId, isNull);
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
      'falls back to terminal_id when name, title and agent are all absent',
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

    test('reads the agent field when neither name nor title is present — a '
        'real herdr agent carries neither, so without it every agent in the '
        'app reads as an opaque terminal id', () async {
      // The payload below is the VERBATIM live capture (see
      // [_blockedAgentInfo]): `name` and `title` are genuinely absent
      // from a real `agent list`, while `agent` carries "claude". A
      // fallback chain that stops before `agent` therefore never
      // produces a readable label on any real host.
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(
          stdout: _agentListSuccess([_blockedAgentInfo]),
          exitCode: 0,
        ),
      );

      final result = await adapter.listAgents();

      final agent = (result as MuxAgentsAvailable).agents.single;
      expect(agent.label, 'claude');
      expect(agent.label, isNot('term_659ab3dc3a8541'));
    });

    test('name still wins over agent', () async {
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(
          stdout: _agentListSuccess([
            {..._blockedAgentInfo, 'name': 'my-name', 'title': 'my-title'},
          ]),
          exitCode: 0,
        ),
      );

      final result = await adapter.listAgents();

      expect((result as MuxAgentsAvailable).agents.single.label, 'my-name');
    });

    test('title still wins over agent', () async {
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(
          stdout: _agentListSuccess([
            {..._blockedAgentInfo, 'title': 'my-title'},
          ]),
          exitCode: 0,
        ),
      );

      final result = await adapter.listAgents();

      expect((result as MuxAgentsAvailable).agents.single.label, 'my-title');
    });

    test('reports a genuinely empty list when the server IS running', () async {
      runner.whenRun(
        _agentListCommand,
        HostCommandResult(stdout: _agentListSuccess(const []), exitCode: 0),
      );

      final result = await adapter.listAgents();

      expect(result, isA<MuxAgentsAvailable>());
      expect((result as MuxAgentsAvailable).agents, isEmpty);
    });

    test('reports a typed server-not-running state, never an empty list, '
        'when the herdr agent-tracking server is down', () async {
      runner.whenRun(
        _agentListCommand,
        const HostCommandResult(stderr: _agentListNoServer, exitCode: 1),
      );

      final result = await adapter.listAgents();

      expect(result, isA<MuxAgentServerNotRunning>());
    });

    test('throws instead of silently collapsing an unrecognized error.code '
        'into server-not-running', () async {
      runner.whenRun(
        _agentListCommand,
        const HostCommandResult(
          stderr: _agentListUnrecognizedError,
          exitCode: 1,
        ),
      );

      expect(() => adapter.listAgents(), throwsStateError);
    });

    test('stderr that is not the JSON error envelope at all is surfaced, not '
        'guessed at — a malformed failure must never be read as a '
        'recognized code', () async {
      // e.g. the binary died before it could write its envelope, or a
      // shell wrapper wrote its own message. There is no `error.code`
      // to parse, so `server_not_running` must NOT be inferred.
      runner.whenRun(
        _agentListCommand,
        const HostCommandResult(
          stderr: 'herdr: command terminated by signal 9',
          exitCode: 137,
        ),
      );

      await expectLater(
        adapter.listAgents(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no machine-readable error.code'),
          ),
        ),
      );
    });
  });

  group('agents capability', () {
    test('is non-null — HerdrAdapter supports agent state', () {
      expect(adapter.agents, isNotNull);
    });

    test('a caller resolving agent support gets the live agent surface', () {
      final support = AgentSupport.resolve(adapter);

      expect(support, isA<AgentSupportAvailable>());
    });

    test('advertises agentWait now that waitForAgent really blocks on '
        'herdr agent wait', () {
      // Asserted as an EXACT set, not with `contains`, so a capability
      // gained or lost is a decision someone has to make here rather
      // than a silent drift. workspaceTree joined it when the drawer
      // learned to read herdr's workspaces and tabs.
      expect(adapter.capabilities, {
        MuxCapability.agentState,
        MuxCapability.agentWait,
        MuxCapability.structuredOutput,
        MuxCapability.paneListing,
        MuxCapability.workspaceTree,
      });
    });
  });

  // CONFIRMED against the real host, from the resurrected-empty session
  // this capability exists to detect:
  //
  //   herdr pane list --session default
  //   → {"id":"cli:pane:list","result":{"panes":[...],"type":"pane_list"}}
  //
  // Every pane carried: pane_id, tab_id, workspace_id, terminal_id,
  // revision (int), cwd, foreground_cwd, focused (bool), agent_status,
  // terminal_title, terminal_title_stripped, scroll (object). This adapter
  // reads only pane_id, revision and cwd — the three the verdict rests on.
  //
  // `pane list` is SOCKET-backed like `agent list`, not directory-backed
  // like `session list --json`: it reports live pane state, so it uses the
  // `{id, result}` / `{id, error: {code, message}}` envelope and fails with
  // `server_not_running` when no server is up.
  group('listPanes', () {
    test('parses the three fields the vitality verdict rests on', () async {
      runner.whenRun(
        _paneListCommand,
        HostCommandResult(
          stdout: _paneListSuccess(const [_virginPaneInfo]),
          exitCode: 0,
        ),
      );

      final result = await adapter.listPanes();

      expect(result, isA<MuxPanesAvailable>());
      final panes = (result as MuxPanesAvailable).panes;
      expect(panes.single.paneId, 'w1:p1');
      expect(panes.single.revision, 1);
      expect(panes.single.cwd, '/home/deployer');
    });

    test('reads every pane, not just the first', () async {
      runner.whenRun(
        _paneListCommand,
        HostCommandResult(
          stdout: _paneListSuccess([
            _virginPaneInfo,
            {..._virginPaneInfo, 'pane_id': 'w1:p2', 'revision': 12},
          ]),
          exitCode: 0,
        ),
      );

      final result = await adapter.listPanes();

      expect((result as MuxPanesAvailable).panes.map((p) => p.revision), [
        1,
        12,
      ]);
    });

    test('a live server with genuinely zero panes is AVAILABLE-but-empty, not '
        'a failure', () async {
      runner.whenRun(
        _paneListCommand,
        HostCommandResult(stdout: _paneListSuccess(const []), exitCode: 0),
      );

      final result = await adapter.listPanes();

      expect(result, isA<MuxPanesAvailable>());
      expect((result as MuxPanesAvailable).panes, isEmpty);
    });

    test(
      'a dead server reports MuxPaneServerNotRunning, never an empty list — '
      'an empty list here would read as "this session has no panes"',
      () async {
        runner.whenRun(
          _paneListCommand,
          HostCommandResult(stderr: _paneListNoServer, exitCode: 1),
        );

        final result = await adapter.listPanes();

        expect(result, isA<MuxPaneServerNotRunning>());
        expect(result, isNot(isA<MuxPanesAvailable>()));
      },
    );

    test('an unrecognized error code is surfaced loudly, never collapsed into '
        'the expected server_not_running state', () async {
      runner.whenRun(
        _paneListCommand,
        HostCommandResult(
          stderr:
              '{"id":"cli:pane:list","error":{"code":"session_not_found",'
              '"message":"no such session"}}',
          exitCode: 1,
        ),
      );

      await expectLater(adapter.listPanes(), throwsStateError);
    });

    test('stderr that is not the JSON envelope at all also throws', () async {
      runner.whenRun(
        _paneListCommand,
        HostCommandResult(stderr: 'Segmentation fault', exitCode: 139),
      );

      await expectLater(adapter.listPanes(), throwsStateError);
    });
  });

  group('listPanes command shape', () {
    test('is socket-backed, so it is scoped to the session', () async {
      const expected = "herdr --session 'helm-0' pane list";
      final scopedRunner = FakeHostCommandRunner()
        ..whenRun(
          expected,
          HostCommandResult(stdout: _paneListSuccess(const []), exitCode: 0),
        );
      final scoped = HerdrAdapter(scopedRunner, sessionRef: 'helm-0');

      await scoped.listPanes();

      expect(scopedRunner.runCalls, [expected]);
    });

    // Pins the ONE spelling, not a claim about the other one.
    //
    // This test used to be named for the assertion that the trailing
    // spelling is "rejected outright by the real binary". Re-measured
    // against live herdr 0.8.0 and 0.8.2, that is false — the trailing form
    // exits 0 on both. What remains true, and what this pins, is that the
    // leading placement works everywhere this app has been measured, so it
    // is the only spelling emitted. See [_agentListCommand]'s doc comment.
    test('the --session flag precedes the subcommand, because leading '
        'placement is the spelling verified on every measured herdr', () async {
      final scopedRunner = FakeHostCommandRunner();
      final scoped = HerdrAdapter(scopedRunner, sessionRef: 'helm-0');
      scopedRunner.whenRun(
        "herdr --session 'helm-0' pane list",
        HostCommandResult(stdout: _paneListSuccess(const []), exitCode: 0),
      );

      await scoped.listPanes();

      final emitted = scopedRunner.runCalls.single;
      expect(emitted.indexOf('--session'), lessThan(emitted.indexOf('pane')));
    });

    test(
      'an adapter built without a session emits no --session flag',
      () async {
        runner.whenRun(
          _paneListCommand,
          HostCommandResult(stdout: _paneListSuccess(const []), exitCode: 0),
        );

        await adapter.listPanes();

        expect(runner.runCalls.single, isNot(contains('--session')));
      },
    );

    test('uses the probe-resolved absolute path, not a bare name', () async {
      const absPath = '/home/deployer/.local/bin/herdr';
      const expected = "$absPath --session 'helm-0' pane list";
      final scopedRunner = FakeHostCommandRunner()
        ..whenRun(
          expected,
          HostCommandResult(stdout: _paneListSuccess(const []), exitCode: 0),
        );
      final scoped = HerdrAdapter(
        scopedRunner,
        absPath: absPath,
        sessionRef: 'helm-0',
      );

      await scoped.listPanes();

      expect(scopedRunner.runCalls, [expected]);
    });

    test('shell-quotes a hostile session ref', () async {
      const name = 'x; rm -rf ~';
      final expected = 'herdr --session ${shellQuote(name)} pane list';
      final scopedRunner = FakeHostCommandRunner()
        ..whenRun(
          expected,
          HostCommandResult(stdout: _paneListSuccess(const []), exitCode: 0),
        );
      final scoped = HerdrAdapter(scopedRunner, sessionRef: name);

      await scoped.listPanes();

      expect(scopedRunner.runCalls, [expected]);
    });
  });

  group('panes capability', () {
    test('is non-null — HerdrAdapter can report pane state', () {
      expect(adapter.panes, isNotNull);
    });
  });

  group('waitForAgent — a REAL blocking wait on herdr agent wait', () {
    // MEASURED against a real herdr 0.8.0 binary, not assumed. This
    // subcommand was previously dismissed as unverified, and this adapter
    // faked the wait with `agent list` plus a filter. Every fact below
    // comes from a live invocation:
    //
    //   $ herdr agent wait --help
    //     Usage: herdr agent wait <TARGET> [OPTIONS]
    //       --until <STATUS>  State to match; repeat for more than one
    //                         state [idle, working, blocked, done, unknown]
    //       --timeout <MS>    Fail after this many milliseconds
    //     Without --until, matches idle, done, or blocked.
    //     Without --timeout, waits indefinitely.
    //
    // EVENT-DRIVEN, not internally polled: with the wait armed, the host
    // state was flipped after 5s of sleep and the call returned at
    // 5.055s — a 55ms reaction. Internal polling would have cost up to a
    // whole interval more.
    //
    // ALREADY-MATCHING RETURNS IMMEDIATELY: against an agent already
    // `blocked`, `--until blocked --timeout 3000` returned in 0.115s
    // (process startup) with a success envelope. Against the same agent,
    // `--until idle --until working --until done --until unknown
    // --timeout 3000` timed out at 3.13s. That is why a caller must arm
    // the COMPLEMENT of the current state — see TerminalSession.
    //
    // Success envelope (verbatim, exit 0):
    //   {"id":"cli:agent:wait","result":{"agent":{...},
    //    "type":"agent_info"}}
    // Timeout envelope (verbatim, exit 1, on stderr):
    //   {"error":{"code":"timeout","message":"timed out waiting for agent
    //    status"},"id":"cli:agent:wait"}
    // Wrong identifier (verbatim, exit 1, on stderr):
    //   {"error":{"code":"agent_not_found","message":"agent target
    //    term_659ab3dc3a8541 not found"},"id":"cli:agent:wait"}

    test('emits the real agent wait command: pane target, one --until per '
        'requested state, and the timeout in milliseconds', () async {
      // The command STRING is the assertion, not the parse. Two defects
      // in this adapter's history — the trailing `--session` spelling
      // and the terminal-id target — both lived in the emitted command
      // while canned stdout kept the parse tests green. This is the
      // shape that catches the third one.
      const expected =
          "herdr agent wait 'w1:p1' --until working --until blocked "
          '--timeout 300000';
      runner.whenRun(
        expected,
        HostCommandResult(
          stdout: _agentWaitSuccess(_blockedAgentInfo),
          exitCode: 0,
        ),
      );

      await adapter.waitForAgent(
        'w1:p1',
        until: {AgentState.blocked, AgentState.working},
        timeout: const Duration(minutes: 5),
      );

      expect(runner.runCalls, [expected]);
    });

    test('orders --until by state, so the emitted command does not depend on '
        'the order a caller happened to build its set in', () async {
      const expected =
          "herdr agent wait 'w1:p1' --until idle --until working "
          '--until blocked --until done --until unknown --timeout 1000';
      runner.whenRun(
        expected,
        HostCommandResult(
          stdout: _agentWaitSuccess(_blockedAgentInfo),
          exitCode: 0,
        ),
      );

      await adapter.waitForAgent(
        'w1:p1',
        until: {
          AgentState.unknown,
          AgentState.done,
          AgentState.blocked,
          AgentState.working,
          AgentState.idle,
        },
        timeout: const Duration(seconds: 1),
      );

      expect(runner.runCalls, [expected]);
    });

    test('shell-quotes the target, which reaches a remote shell', () async {
      const expected =
          "herdr agent wait 'w1:p1;rm -rf /' --until blocked --timeout 1000";
      runner.whenRun(
        expected,
        HostCommandResult(
          stdout: _agentWaitSuccess(_blockedAgentInfo),
          exitCode: 0,
        ),
      );

      await adapter.waitForAgent(
        'w1:p1;rm -rf /',
        until: {AgentState.blocked},
        timeout: const Duration(seconds: 1),
      );

      expect(runner.runCalls, [expected]);
    });

    test('never falls back to agent list — it is a wait now, not a list plus '
        'a filter', () async {
      // `agent list` is deliberately left UNREGISTERED: the fake throws
      // for an unscripted command, so a regression to the old
      // single-shot implementation fails loudly here.
      runner.whenRun(
        "herdr agent wait 'w1:p1' --until blocked --timeout 1000",
        HostCommandResult(
          stdout: _agentWaitSuccess(_blockedAgentInfo),
          exitCode: 0,
        ),
      );

      await adapter.waitForAgent(
        'w1:p1',
        until: {AgentState.blocked},
        timeout: const Duration(seconds: 1),
      );

      expect(runner.runCalls.single, contains('agent wait'));
      expect(runner.runCalls.single, isNot(contains('agent list')));
    });

    test('reports the matched agent, parsed from the wait envelope', () async {
      runner.whenRun(
        "herdr agent wait 'w1:p1' --until blocked --timeout 1000",
        HostCommandResult(
          stdout: _agentWaitSuccess(_blockedAgentInfo),
          exitCode: 0,
        ),
      );

      final result = await adapter.waitForAgent(
        'w1:p1',
        until: {AgentState.blocked},
        timeout: const Duration(seconds: 1),
      );

      expect(result, isA<MuxAgentWaitMatched>());
      expect((result as MuxAgentWaitMatched).agent, (
        target: 'w1:p1',
        label: 'claude',
        state: AgentState.blocked,
        tabId: 'w1:t1',
        workspaceId: 'w1',
      ));
    });

    test('a herdr timeout is TIMED OUT, never FAILED — nothing changed is not '
        'an error, and a caller must be free to simply re-arm', () async {
      runner.whenRun(
        "herdr agent wait 'w1:p1' --until blocked --timeout 1000",
        const HostCommandResult(stderr: _agentWaitTimeout, exitCode: 1),
      );

      final result = await adapter.waitForAgent(
        'w1:p1',
        until: {AgentState.blocked},
        timeout: const Duration(seconds: 1),
      );

      expect(result, isA<MuxAgentWaitTimedOut>());
      expect(result, isNot(isA<MuxAgentWaitFailed>()));
    });

    test(
      'a vanished target is FAILED and carries the code, never TIMED OUT — '
      'a caller must not read "the pane is gone" as "nothing changed"',
      () async {
        runner.whenRun(
          "herdr agent wait 'w1:p1' --until blocked --timeout 1000",
          const HostCommandResult(stderr: _agentWaitNotFound, exitCode: 1),
        );

        final result = await adapter.waitForAgent(
          'w1:p1',
          until: {AgentState.blocked},
          timeout: const Duration(seconds: 1),
        );

        expect(result, isA<MuxAgentWaitFailed>());
        expect((result as MuxAgentWaitFailed).code, 'agent_not_found');
      },
    );

    test('a dead agent server is FAILED, never TIMED OUT', () async {
      runner.whenRun(
        "herdr agent wait 'w1:p1' --until blocked --timeout 1000",
        const HostCommandResult(stderr: _agentWaitNoServer, exitCode: 1),
      );

      final result = await adapter.waitForAgent(
        'w1:p1',
        until: {AgentState.blocked},
        timeout: const Duration(seconds: 1),
      );

      expect(result, isA<MuxAgentWaitFailed>());
      expect((result as MuxAgentWaitFailed).code, 'server_not_running');
    });

    test('stderr that is not herdr JSON at all is FAILED with no code, not '
        'silently read as a timeout', () async {
      runner.whenRun(
        "herdr agent wait 'w1:p1' --until blocked --timeout 1000",
        const HostCommandResult(
          stderr: 'herdr: command not found',
          exitCode: 127,
        ),
      );

      final result = await adapter.waitForAgent(
        'w1:p1',
        until: {AgentState.blocked},
        timeout: const Duration(seconds: 1),
      );

      expect(result, isA<MuxAgentWaitFailed>());
      expect((result as MuxAgentWaitFailed).code, isNull);
    });

    test('a transport that gave up without an exit code is FAILED, never a '
        'timeout that invites an immediate re-arm', () async {
      runner.whenRun(
        "herdr agent wait 'w1:p1' --until blocked --timeout 1000",
        const HostCommandResult(timedOut: true),
      );

      final result = await adapter.waitForAgent(
        'w1:p1',
        until: {AgentState.blocked},
        timeout: const Duration(seconds: 1),
      );

      expect(result, isA<MuxAgentWaitFailed>());
    });

    test('an empty until set is rejected outright — herdr would silently '
        'substitute its own default of idle|done|blocked', () async {
      expect(
        () => adapter.waitForAgent(
          'w1:p1',
          until: const {},
          timeout: const Duration(seconds: 1),
        ),
        throwsArgumentError,
      );
      expect(runner.runCalls, isEmpty);
    });
  });

  group('focusAgent — bringing the agent`s pane to the front', () {
    // MEASURED against a real herdr 0.8.2 binary, not assumed:
    //
    //   $ herdr agent focus --help
    //     Focus an agent
    //     Usage: herdr agent focus <target>
    //     Arguments:
    //       <target>
    //
    // The target is POSITIONAL — there is no `--target` flag — and it is
    // the PANE id, the same identifier `agent wait` accepts and the same
    // one `AgentStatus.target` already carries. Confirmed by feeding it a
    // terminal id: `herdr agent focus term_65a07c99f57a51` answers
    // `agent_not_found`, exactly as `agent wait` does.
    //
    // Three outcomes were observed, and all three are distinguishable
    // from the exit code plus `error.code` alone:
    //   exit 0 → {"id":"cli:agent:focus","result":{"agent":{...},
    //             "type":"agent_info"}}      (stdout)
    //   exit 1 → {"error":{"code":"agent_not_found", ...}}   (stderr)
    //   exit 1 → {"error":{"code":"server_not_running", ...}} (stderr)

    test('emits the real focus command with the target POSITIONAL and shell-'
        'quoted, because it reaches a remote shell', () async {
      // The command STRING is the assertion, not the parse. Every defect
      // this adapter has shipped lived in the emitted command while the
      // parse stayed green — the trailing `--session` spelling and the
      // terminal-id target both did. A `--target` flag would be the
      // third, and herdr rejects it outright.
      const expected = "herdr agent focus 'w1:p1'";
      runner.whenRun(
        expected,
        HostCommandResult(
          stdout: _agentFocusSuccess(_blockedAgentInfo),
          exitCode: 0,
        ),
      );

      await adapter.focusAgent('w1:p1');

      expect(runner.runCalls, [expected]);
      expect(runner.runCalls.single, isNot(contains('--target')));
    });

    test('shell-quotes a hostile target', () async {
      const expected = "herdr agent focus 'w1:p1;rm -rf /'";
      runner.whenRun(
        expected,
        HostCommandResult(
          stdout: _agentFocusSuccess(_blockedAgentInfo),
          exitCode: 0,
        ),
      );

      await adapter.focusAgent('w1:p1;rm -rf /');

      expect(runner.runCalls, [expected]);
    });

    test('the focus is scoped, and --session still precedes the subcommand — '
        'an unscoped focus would raise a pane in another session', () async {
      const expected = "herdr --session 'helm-0' agent focus 'w1:p1'";
      final scopedRunner = FakeHostCommandRunner();
      // Both spellings are canned so a regression fails on the ASSERTION
      // that names the defect, not on the fake having nothing registered.
      for (final command in const [expected, "herdr agent focus 'w1:p1'"]) {
        scopedRunner.whenRun(
          command,
          HostCommandResult(
            stdout: _agentFocusSuccess(_blockedAgentInfo),
            exitCode: 0,
          ),
        );
      }
      final scoped = HerdrAdapter(scopedRunner, sessionRef: 'helm-0');

      await scoped.focusAgent('w1:p1');

      final emitted = scopedRunner.runCalls.single;
      expect(emitted, expected);
      expect(
        emitted.indexOf('--session'),
        lessThan(emitted.indexOf('agent focus')),
      );
    });

    test('exit 0 is FOCUSED', () async {
      runner.whenRun(
        "herdr agent focus 'w1:p1'",
        HostCommandResult(
          stdout: _agentFocusSuccess(_blockedAgentInfo),
          exitCode: 0,
        ),
      );

      expect(await adapter.focusAgent('w1:p1'), isA<MuxAgentFocused>());
    });

    test('a success body this adapter never parses cannot break the success '
        'path — the exit code is what decides it', () async {
      // herdr could add a field, drop `agent`, or change `type` and this
      // must keep working: nothing downstream reads the body. Asserting
      // it here is what stops a future contributor "helpfully" parsing a
      // payload no caller wants.
      runner.whenRun(
        "herdr agent focus 'w1:p1'",
        const HostCommandResult(stdout: 'not json at all', exitCode: 0),
      );

      expect(await adapter.focusAgent('w1:p1'), isA<MuxAgentFocused>());
    });

    test('a vanished pane is TARGET NOT FOUND, never a generic failure — the '
        'drawer showed the user a row that is gone, and that is a different '
        'thing to say than "we could not reach the host"', () async {
      runner.whenRun(
        "herdr agent focus 'w99:p99'",
        const HostCommandResult(stderr: _agentFocusNotFound, exitCode: 1),
      );

      final result = await adapter.focusAgent('w99:p99');

      expect(result, isA<MuxAgentFocusTargetNotFound>());
      expect(result, isNot(isA<MuxAgentFocusFailed>()));
      expect(result, isNot(isA<MuxAgentFocused>()));
    });

    test(
      'a dead agent server is FAILED and carries the code, never FOCUSED',
      () async {
        runner.whenRun(
          "herdr agent focus 'w1:p1'",
          const HostCommandResult(stderr: _agentFocusNoServer, exitCode: 1),
        );

        final result = await adapter.focusAgent('w1:p1');

        expect(result, isA<MuxAgentFocusFailed>());
        expect((result as MuxAgentFocusFailed).code, 'server_not_running');
      },
    );

    test(
      'an unrecognized code is reported AS ITSELF — never silently mapped '
      'onto server_not_running and never onto a target that is missing',
      () async {
        runner.whenRun(
          "herdr agent focus 'w1:p1'",
          const HostCommandResult(
            stderr:
                '{"id":"cli:agent:focus","error":{"code":"internal_error",'
                '"message":"unexpected failure"}}',
            exitCode: 1,
          ),
        );

        final result = await adapter.focusAgent('w1:p1');

        expect(result, isA<MuxAgentFocusFailed>());
        expect((result as MuxAgentFocusFailed).code, 'internal_error');
        expect(result, isNot(isA<MuxAgentFocusTargetNotFound>()));
      },
    );

    test('stderr that is not herdr JSON at all is FAILED with a NULL code, so '
        'an unrecognized failure is reported as unrecognized', () async {
      runner.whenRun(
        "herdr agent focus 'w1:p1'",
        const HostCommandResult(
          stderr: 'herdr: command not found',
          exitCode: 127,
        ),
      );

      final result = await adapter.focusAgent('w1:p1');

      expect(result, isA<MuxAgentFocusFailed>());
      expect((result as MuxAgentFocusFailed).code, isNull);
    });

    test('a transport that gave up without an exit code is FAILED — nothing '
        'is known about whether the pane was raised', () async {
      runner.whenRun(
        "herdr agent focus 'w1:p1'",
        const HostCommandResult(timedOut: true),
      );

      expect(await adapter.focusAgent('w1:p1'), isA<MuxAgentFocusFailed>());
    });
  });

  group('listSessions', () {
    test('reports the default session as exited when no server is running, '
        'never an empty list', () async {
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
    });

    test('reports a typed failure state, never a crash, when the list '
        'command fails for an unspecified reason', () async {
      // No verified failure sample exists for a genuinely non-zero
      // exit here (see the apply report's D2) — this locks in that the
      // fallback is a defined typed state, not a crash.
      runner.whenRun(
        _sessionListCommand,
        const HostCommandResult(stderr: 'unexpected failure', exitCode: 2),
      );

      final result = await adapter.listSessions();

      expect(result, isA<MuxServerNotRunning>());
    });

    test('a genuinely empty session list is reported when the server IS '
        'running and herdr has zero known sessions', () async {
      runner.whenRun(
        _sessionListCommand,
        const HostCommandResult(stdout: _sessionListEmpty, exitCode: 0),
      );

      final result = await adapter.listSessions();

      expect(result, isA<MuxSessionsAvailable>());
      expect((result as MuxSessionsAvailable).sessions, isEmpty);
    });

    test('reports each session state from the running boolean, not a '
        'status string', () async {
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
    });
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

    test('returns false when the list command fails for an unspecified '
        'reason', () async {
      runner.whenRun(
        _sessionListCommand,
        const HostCommandResult(stderr: 'unexpected failure', exitCode: 2),
      );

      expect(await adapter.hasSession('work'), isFalse);
    });
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

  // ── Session scoping ──────────────────────────────────────────────────────
  //
  // These assert on the EMITTED COMMAND STRING, not on the parse of a
  // canned stdout, because that is where the defect actually lived.
  //
  // MEASURED on a real herdr 0.8.0 host: every herdr session owns its own
  // api socket (`~/.config/herdr/sessions/<name>/herdr.sock` versus the
  // default session's `~/.config/herdr/herdr.sock`), and `agent list`
  // answers only for the socket it connects to. A bare `herdr agent list`
  // issued while attached to session `helm-0` returned `agents: []` at the
  // same instant `herdr --session helm-0 agent list` returned a BLOCKED
  // agent — a confident, wrong "no agents are running" about the one state
  // this whole feature exists to surface.
  //
  // No canned-stdout test could catch that: both spellings parse
  // identically, and the wrong one simply asks the wrong socket. The only
  // thing that separates them is the command string, so that is what these
  // pin. `--session` is a GLOBAL option and MUST precede the subcommand —
  // verified against the real binary, which rejects the trailing-flag
  // spellings outright.
  group('session scoping', () {
    /// A runner that answers BOTH the scoped and the unscoped spelling of
    /// `agent list` with the same empty result.
    ///
    /// Registering both matters: [FakeHostCommandRunner] throws for an
    /// unregistered command, so a runner that only knew the correct
    /// spelling would fail a regression with a `StateError` from the
    /// harness rather than with the assertion that names the defect. These
    /// tests must fail on "the emitted command was wrong", not on "the
    /// fake had nothing canned".
    FakeHostCommandRunner ambidextrousRunner() {
      final local = FakeHostCommandRunner();
      for (final command in const [
        _agentListCommand,
        "herdr --session 'helm-0' agent list",
      ]) {
        local.whenRun(
          command,
          HostCommandResult(stdout: _agentListSuccess(const []), exitCode: 0),
        );
      }
      return local;
    }

    test(
      'an adapter built for a session scopes agent list to that session',
      () async {
        final scopedRunner = ambidextrousRunner();
        final scoped = HerdrAdapter(scopedRunner, sessionRef: 'helm-0');

        await scoped.listAgents();

        expect(scopedRunner.runCalls, ["herdr --session 'helm-0' agent list"]);
      },
    );

    test(
      'an adapter built without a session emits no --session flag at all',
      () async {
        runner.whenRun(
          _agentListCommand,
          HostCommandResult(stdout: _agentListSuccess(const []), exitCode: 0),
        );

        await adapter.listAgents();

        expect(runner.runCalls, ['herdr agent list']);
        expect(runner.runCalls.single, isNot(contains('--session')));
      },
    );

    test(
      'the --session flag precedes the subcommand, never trails it',
      () async {
        final scopedRunner = ambidextrousRunner();
        final scoped = HerdrAdapter(scopedRunner, sessionRef: 'helm-0');

        await scoped.listAgents();

        final emitted = scopedRunner.runCalls.single;
        expect(emitted, contains('--session'));
        expect(
          emitted.indexOf('--session'),
          lessThan(emitted.indexOf('agent list')),
        );
      },
    );

    test('scopes with the resolved absolute path, not a bare name', () async {
      const absPath = '/home/deployer/.local/bin/herdr';
      final scopedRunner = FakeHostCommandRunner();
      scopedRunner.whenRun(
        "$absPath --session 'helm-0' agent list",
        HostCommandResult(stdout: _agentListSuccess(const []), exitCode: 0),
      );
      final scoped = HerdrAdapter(
        scopedRunner,
        absPath: absPath,
        sessionRef: 'helm-0',
      );

      await scoped.listAgents();

      expect(scopedRunner.runCalls, ["$absPath --session 'helm-0' agent list"]);
    });

    test('the wait is scoped too, and --session still precedes the '
        'subcommand — an unscoped wait would watch another session', () async {
      // Reproduces the measured lie in the wait's shape: the UNSCOPED
      // spelling talks to herdr's DEFAULT session socket, where the pane
      // this session is attached to does not exist at all — so an
      // unscoped wait does not merely watch the wrong agent, it fails
      // with agent_not_found forever.
      const expected =
          "herdr --session 'helm-0' agent wait 'w1:p1' --until blocked "
          '--timeout 1000';
      final scopedRunner = FakeHostCommandRunner();
      // Both spellings are canned so a regression fails on the
      // ASSERTION that names the defect, not on the fake having nothing
      // registered.
      for (final command in const [
        expected,
        "herdr agent wait 'w1:p1' --until blocked --timeout 1000",
      ]) {
        scopedRunner.whenRun(
          command,
          HostCommandResult(
            stdout: _agentWaitSuccess(_blockedAgentInfo),
            exitCode: 0,
          ),
        );
      }
      final scoped = HerdrAdapter(scopedRunner, sessionRef: 'helm-0');

      await scoped.waitForAgent(
        'w1:p1',
        until: const {AgentState.blocked},
        timeout: const Duration(seconds: 1),
      );

      final emitted = scopedRunner.runCalls.single;
      expect(emitted, expected);
      expect(
        emitted.indexOf('--session'),
        lessThan(emitted.indexOf('agent wait')),
      );
    });

    test('session list stays UNSCOPED even on a scoped adapter — enumerating '
        'every session is a global question', () async {
      final scopedRunner = FakeHostCommandRunner();
      scopedRunner.whenRun(
        _sessionListCommand,
        const HostCommandResult(stdout: _sessionListEmpty, exitCode: 0),
      );
      final scoped = HerdrAdapter(scopedRunner, sessionRef: 'helm-0');

      await scoped.listSessions();

      expect(scopedRunner.runCalls, ['herdr session list --json']);
    });

    test('detect stays UNSCOPED even on a scoped adapter', () async {
      final scopedRunner = FakeHostCommandRunner();
      scopedRunner.whenRun(
        _detectCommand,
        const HostCommandResult(stdout: 'herdr 0.8.0', exitCode: 0),
      );
      final scoped = HerdrAdapter(scopedRunner, sessionRef: 'helm-0');

      await scoped.detect();

      expect(scopedRunner.runCalls, [_detectCommand]);
    });

    test('attachCommand is unaffected by the session scope — it names its '
        'target session as a positional argument already', () {
      final scoped = HerdrAdapter(runner, sessionRef: 'helm-0');

      expect(scoped.attachCommand('work'), "herdr session attach 'work'");
    });

    group('shell-quotes the session name', () {
      // Session refs reach a remote login shell, and unlike the positional
      // name in `attachCommand` this one rides a GLOBAL flag. An unquoted
      // ref with a separator would not merely pick the wrong session — it
      // would run a second command.
      for (final name in const [
        'x; rm -rf ~',
        r'$(id)',
        "O'Brien",
        '-rf',
        'has space',
      ]) {
        test(name, () async {
          final expected = 'herdr --session ${shellQuote(name)} agent list';
          final scopedRunner = FakeHostCommandRunner();
          scopedRunner.whenRun(
            expected,
            HostCommandResult(stdout: _agentListSuccess(const []), exitCode: 0),
          );
          final scoped = HerdrAdapter(scopedRunner, sessionRef: name);

          await scoped.listAgents();

          expect(scopedRunner.runCalls, [expected]);
        });
      }
    });
  });
}
