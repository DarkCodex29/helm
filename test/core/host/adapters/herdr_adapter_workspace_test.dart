// Unit tests for herdr's workspace/tab surface.
//
// helm's drawer showed the SSH profile — one row, "My Server" — while
// herdr on that host already knew the structure the owner thinks in:
// workspaces are his clients, tabs are their projects. Reaching one meant
// driving herdr's TUI with a phone keyboard, the chore helm exists to
// remove. These tests pin the wire contract that makes the tree readable.
//
// CONFIRMED against the owner's live herdr 0.8.2, captured verbatim
// (`herdr --version` → `herdr 0.8.2`):
//
// - `workspace list` and `tab list` are SOCKET-backed, like `agent list`
//   and unlike `session list --json`: both answer in the `{id, result}`
//   envelope, with `"id":"cli:workspace:list"` / `"id":"cli:tab:list"`.
// - Workspace fields: workspace_id, label, number, tab_count, pane_count,
//   agent_status, focused, active_tab_id.
// - Tab fields: tab_id, workspace_id, label, number, pane_count,
//   agent_status, focused.
// - `agent_status` uses the SAME vocabulary as `agent list` — observed
//   working / idle / unknown — so [AgentState] parses it unchanged.
// - No-server failure: exit 1, stdout EMPTY, and the error envelope on
//   STDERR — verified by redirecting each stream separately:
//   {"id":"cli:workspace:list","error":{"code":"server_not_running",
//   "message":"no herdr server is running at …"}}
// - `--session` is accepted as a GLOBAL option before both subcommands:
//   `herdr --session helm-0 tab list` reached that session's own socket
//   (the error names `sessions/helm-0/herdr.sock`), proving the scope is
//   honoured rather than ignored.
// - `herdr tab focus --help` → `Usage: herdr tab focus <tab_id>`. The
//   target is POSITIONAL; there is no `--tab-id` flag.
//
// - THE TAB LIST IS NOT IN TAB-BAR ORDER. Captured live, workspace w2 came
//   back 5,1,2,3,4,6 — the FOCUSED tab hoisted to the front. Ordering the
//   tree by arrival would therefore reshuffle the list the instant a user
//   taps a row. This adapter deliberately does NOT reorder (a consumer is
//   entitled to the host's own order); `number` is carried so the drawer
//   can sort, and `shortcuts_drawer_workspaces_test.dart` is where that
//   stable order is enforced.
//
// READ OUT OF THE BINARY, NOT FROM A LIVE INVOCATION: the focus
// not-found code is `tab_not_found`, found in herdr 0.8.2's string table
// alongside `pane_not_found` and the message "tab not found". It is NOT
// confirmed by running `tab focus`, because the only herdr available was
// the owner's live session holding real client work and a focus would
// have moved his screen. Weaker evidence than the rest of this file, and
// recorded as such — but the alternative was guessing by analogy to
// `agent_not_found`, which is weaker still.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/adapters/herdr_adapter.dart';
import 'package:helm/core/host/adapters/tmux_adapter.dart';
import 'package:helm/core/host/adapters/zellij_adapter.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';

import '../../../helpers/fake_host_command_runner.dart';

const _workspaceListCommand = 'herdr workspace list';
const _tabListCommand = 'herdr tab list';

/// Captured verbatim from the owner's live herdr 0.8.2, trimmed to two
/// workspaces. Field order and spelling are the host's, not this test's.
const _workspaceListJson =
    '{"id":"cli:workspace:list","result":{"type":"workspace_list",'
    '"workspaces":['
    '{"active_tab_id":"w1:t1","agent_status":"working","focused":false,'
    '"label":"EBIM","number":1,"pane_count":1,"tab_count":1,'
    '"workspace_id":"w1"},'
    '{"active_tab_id":"w2:t5","agent_status":"idle","focused":true,'
    '"label":"Go Nexa","number":2,"pane_count":6,"tab_count":6,'
    '"workspace_id":"w2"}'
    ']}}';

/// Captured verbatim, same run. Note w2's tabs arrive 5 then 1 — the
/// focused tab first, NOT in tab-bar order.
const _tabListJson =
    '{"id":"cli:tab:list","result":{"tabs":['
    '{"agent_status":"working","focused":false,"label":"Calera","number":1,'
    '"pane_count":1,"tab_id":"w1:t1","workspace_id":"w1"},'
    '{"agent_status":"idle","focused":true,"label":"Helm","number":5,'
    '"pane_count":1,"tab_id":"w2:t5","workspace_id":"w2"},'
    '{"agent_status":"unknown","focused":false,'
    '"label":"Portal de Proveedores","number":1,"pane_count":1,'
    '"tab_id":"w2:t1","workspace_id":"w2"}'
    '],"type":"tab_list"}}';

const _serverDownStderr =
    '{"id":"cli:workspace:list","error":{"code":"server_not_running",'
    '"message":"no herdr server is running at …"}}';

HostCommandResult _ok(String stdout) =>
    HostCommandResult(stdout: stdout, exitCode: 0);

HostCommandResult _failed(String stderr) =>
    HostCommandResult(stderr: stderr, exitCode: 1);

/// A runner with BOTH tree queries scripted to succeed.
FakeHostCommandRunner _healthyRunner() => FakeHostCommandRunner()
  ..whenRun(_workspaceListCommand, _ok(_workspaceListJson))
  ..whenRun(_tabListCommand, _ok(_tabListJson));

void main() {
  group('capability', () {
    test('herdr advertises the workspace tree, and exposes it through the '
        'typed accessor rather than a flag a caller can forget to read', () {
      final adapter = HerdrAdapter(FakeHostCommandRunner());

      expect(adapter.capabilities, contains(MuxCapability.workspaceTree));
      expect(adapter.workspaces, isNotNull);
    });
  });

  group('listWorkspaceTree', () {
    test('issues the exact commands the real binary accepts', () async {
      final runner = _healthyRunner();

      await HerdrAdapter(runner).workspaces!.listWorkspaceTree();

      expect(runner.runCalls, [_workspaceListCommand, _tabListCommand]);
    });

    test('scopes both queries to the session, because a socket-backed query '
        "answers only for the socket it connects to — the same MEASURED trap "
        'that made an unscoped `agent list` report zero agents', () async {
      // The session ref is shell-quoted, like every other host-supplied
      // string that reaches a remote shell (AD-3).
      final runner = FakeHostCommandRunner()
        ..whenRun(
          "herdr --session 'helm-0' workspace list",
          _ok(_workspaceListJson),
        )
        ..whenRun("herdr --session 'helm-0' tab list", _ok(_tabListJson));

      await HerdrAdapter(
        runner,
        sessionRef: 'helm-0',
      ).workspaces!.listWorkspaceTree();

      expect(runner.runCalls, [
        "herdr --session 'helm-0' workspace list",
        "herdr --session 'helm-0' tab list",
      ]);
    });

    test('parses the workspaces the host reported', () async {
      final result = await HerdrAdapter(
        _healthyRunner(),
      ).workspaces!.listWorkspaceTree();

      final tree = result as MuxWorkspaceTreeAvailable;
      expect(tree.workspaces, [
        (
          workspaceId: 'w1',
          label: 'EBIM',
          agentState: AgentState.working,
          activeTabId: 'w1:t1',
        ),
        (
          workspaceId: 'w2',
          label: 'Go Nexa',
          agentState: AgentState.idle,
          activeTabId: 'w2:t5',
        ),
      ]);
    });

    test(
      'a workspace missing active_tab_id parses with a null, rather than '
      'throwing on a field this adapter has only ever seen present',
      () async {
        final runner = FakeHostCommandRunner()
          ..whenRun(
            _workspaceListCommand,
            _ok(
              '{"id":"cli:workspace:list","result":{"type":"workspace_list",'
              '"workspaces":[{"agent_status":"idle","focused":false,'
              '"label":"EBIM","number":1,"pane_count":0,"tab_count":0,'
              '"workspace_id":"w1"}]}}',
            ),
          )
          ..whenRun(
            _tabListCommand,
            _ok('{"id":"cli:tab:list","result":{"tabs":[]}}'),
          );

        final result = await HerdrAdapter(
          runner,
        ).workspaces!.listWorkspaceTree();

        final tree = result as MuxWorkspaceTreeAvailable;
        expect(tree.workspaces.single.activeTabId, isNull);
      },
    );

    test('parses the tabs, keeping the host\'s own order', () async {
      final result = await HerdrAdapter(
        _healthyRunner(),
      ).workspaces!.listWorkspaceTree();

      final tree = result as MuxWorkspaceTreeAvailable;
      expect(tree.tabs.map((t) => t.tabId), ['w1:t1', 'w2:t5', 'w2:t1']);
      expect(tree.tabs[1], (
        tabId: 'w2:t5',
        workspaceId: 'w2',
        label: 'Helm',
        number: 5,
        focused: true,
        agentState: AgentState.idle,
      ));
    });

    test('reuses the agent-status vocabulary rather than parsing it a second '
        'time — the host sends one enum, helm must read one enum', () async {
      final result = await HerdrAdapter(
        _healthyRunner(),
      ).workspaces!.listWorkspaceTree();

      final tree = result as MuxWorkspaceTreeAvailable;
      expect(tree.tabs.map((t) => t.agentState), [
        AgentState.working,
        AgentState.idle,
        AgentState.unknown,
      ]);
    });

    test('a dead server is a TYPED state, never an empty tree — an empty tree '
        'reads as "this host has no workspaces", which is a different claim '
        'from "we could not ask"', () async {
      final runner = FakeHostCommandRunner()
        ..whenRun(_workspaceListCommand, _failed(_serverDownStderr));

      final result = await HerdrAdapter(runner).workspaces!.listWorkspaceTree();

      expect(result, isA<MuxWorkspaceTreeUnreachable>());
    });

    test('a tab query that failed cannot be published as workspaces with no '
        'tabs — that would compose a LIE out of one truth and one failure, '
        'and it would read as "every client has no projects"', () async {
      final runner = FakeHostCommandRunner()
        ..whenRun(_workspaceListCommand, _ok(_workspaceListJson))
        ..whenRun(_tabListCommand, _failed(_serverDownStderr));

      final result = await HerdrAdapter(runner).workspaces!.listWorkspaceTree();

      expect(result, isA<MuxWorkspaceTreeUnreachable>());
    });

    test('an unrecognized error code is surfaced, never collapsed into the '
        'common "server not running" state', () async {
      final runner = FakeHostCommandRunner()
        ..whenRun(
          _workspaceListCommand,
          _failed('{"error":{"code":"something_new"}}'),
        );

      await expectLater(
        HerdrAdapter(runner).workspaces!.listWorkspaceTree(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('something_new'),
          ),
        ),
      );
    });

    test('stderr that is not the JSON envelope at all is also loud', () async {
      final runner = FakeHostCommandRunner()
        ..whenRun(_workspaceListCommand, _failed('herdr: killed'));

      await expectLater(
        HerdrAdapter(runner).workspaces!.listWorkspaceTree(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('listWorkspaceTree — a transport that never answered', () {
    test(
      'a workspace list that timed out is UNREACHABLE, never a crash — the '
      'variant already names "the transport gave up" as one of its cases',
      () async {
        final runner = FakeHostCommandRunner()
          ..whenRun(
            _workspaceListCommand,
            const HostCommandResult(timedOut: true),
          );

        final result = await HerdrAdapter(
          runner,
        ).workspaces!.listWorkspaceTree();

        expect(result, isA<MuxWorkspaceTreeUnreachable>());
      },
    );

    test(
      'a tab list that timed out after a good workspace list is UNREACHABLE '
      'too — half a tree is the one thing this result refuses to report',
      () async {
        final runner = FakeHostCommandRunner()
          ..whenRun(_workspaceListCommand, _ok(_workspaceListJson))
          ..whenRun(_tabListCommand, const HostCommandResult(timedOut: true));

        final result = await HerdrAdapter(
          runner,
        ).workspaces!.listWorkspaceTree();

        expect(result, isA<MuxWorkspaceTreeUnreachable>());
      },
    );
  });

  group('focusTab', () {
    test('passes the tab id POSITIONALLY, shell-quoted', () async {
      final runner = FakeHostCommandRunner()
        ..whenRun("herdr tab focus 'w2:t3'", _ok('{"id":"cli:tab:focus"}'));

      await HerdrAdapter(runner).workspaces!.focusTab('w2:t3');

      expect(runner.runCalls, ["herdr tab focus 'w2:t3'"]);
    });

    test('scopes the focus to the session, like every socket call', () async {
      final runner = FakeHostCommandRunner()
        ..whenRun(
          "herdr --session 'helm-0' tab focus 'w2:t3'",
          _ok('{"id":"cli:tab:focus"}'),
        );

      await HerdrAdapter(
        runner,
        sessionRef: 'helm-0',
      ).workspaces!.focusTab('w2:t3');

      expect(runner.runCalls, ["herdr --session 'helm-0' tab focus 'w2:t3'"]);
    });

    test('exit 0 is the success — the response body is never parsed', () async {
      // Deliberately NOT valid JSON: success is decided by the exit status,
      // so a body helm never reads must not be able to break the one
      // operation the user is waiting on.
      final runner = FakeHostCommandRunner()
        ..whenRun("herdr tab focus 'w1:t1'", _ok('not json at all'));

      final result = await HerdrAdapter(runner).workspaces!.focusTab('w1:t1');

      expect(result, isA<MuxTabFocused>());
    });

    test(
      'a tab that is gone reads DIFFERENTLY from a host we could not ask: '
      'one says this tree is stale, the other says we know nothing',
      () async {
        final runner = FakeHostCommandRunner()
          ..whenRun(
            "herdr tab focus 'w9:t9'",
            _failed('{"error":{"code":"tab_not_found"}}'),
          )
          ..whenRun("herdr tab focus 'w1:t1'", _failed(_serverDownStderr));

        expect(
          await HerdrAdapter(runner).workspaces!.focusTab('w9:t9'),
          isA<MuxTabFocusTargetNotFound>(),
        );
        expect(
          await HerdrAdapter(runner).workspaces!.focusTab('w1:t1'),
          isA<MuxTabFocusFailed>().having(
            (f) => f.code,
            'code',
            'server_not_running',
          ),
        );
      },
    );

    test('a transport that never reported an exit status is a failure, never '
        'a success — nothing is known about whether the tab moved', () async {
      final runner = FakeHostCommandRunner()
        ..whenRun(
          "herdr tab focus 'w1:t1'",
          const HostCommandResult(timedOut: true),
        );

      expect(
        await HerdrAdapter(runner).workspaces!.focusTab('w1:t1'),
        isA<MuxTabFocusFailed>().having(
          (f) => f.code,
          'code',
          'transport_incomplete',
        ),
      );
    });

    test(
      'an unrecognized code is carried, never mapped onto a known one',
      () async {
        final runner = FakeHostCommandRunner()
          ..whenRun(
            "herdr tab focus 'w1:t1'",
            _failed('{"error":{"code":"ui_busy"}}'),
          );

        expect(
          await HerdrAdapter(runner).workspaces!.focusTab('w1:t1'),
          isA<MuxTabFocusFailed>().having((f) => f.code, 'code', 'ui_busy'),
        );
      },
    );
  });

  group('multiplexers that have no workspaces', () {
    test('tmux and zellij decline the capability THROUGH THE TYPE, so a '
        'caller cannot reach the tree without first admitting they have '
        'none — "this multiplexer has no workspaces" can never be read as '
        '"this multiplexer reported no workspaces"', () {
      for (final adapter in [
        TmuxAdapter(FakeHostCommandRunner()),
        ZellijAdapter(FakeHostCommandRunner()),
      ]) {
        expect(adapter.workspaces, isNull, reason: '${adapter.id}');
        expect(
          adapter.capabilities,
          isNot(contains(MuxCapability.workspaceTree)),
          reason: '${adapter.id}',
        );
      }
    });
  });
}
