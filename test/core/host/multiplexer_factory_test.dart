// Unit tests for buildMultiplexerAdapter — the one place a
// MultiplexerSelection becomes a concrete adapter.
//
// The behavior that matters is that the probe-resolved absolute path
// actually reaches the adapter. Without it, a binary installed off the
// inherited PATH (the verified ~/.local/bin/herdr case) would be attached
// to by bare name and fail, defeating the whole point of probing.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/adapters/herdr_adapter.dart';
import 'package:helm/core/host/adapters/tmux_adapter.dart';
import 'package:helm/core/host/adapters/zellij_adapter.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/multiplexer_factory.dart';
import 'package:helm/core/host/multiplexer_selection.dart';

import '../../helpers/fake_host_command_runner.dart';

void main() {
  group('buildMultiplexerAdapter — maps every id to its adapter', () {
    test('tmux', () {
      final adapter = buildMultiplexerAdapter(
        const MultiplexerVerified(
          id: MultiplexerId.tmux,
          absPath: '/usr/bin/tmux',
          onInheritedPath: true,
        ),
        FakeHostCommandRunner(),
      );

      expect(adapter, isA<TmuxAdapter>());
      expect(adapter.id, MultiplexerId.tmux);
    });

    test('zellij', () {
      final adapter = buildMultiplexerAdapter(
        const MultiplexerVerified(
          id: MultiplexerId.zellij,
          absPath: '/usr/bin/zellij',
          onInheritedPath: true,
        ),
        FakeHostCommandRunner(),
      );

      expect(adapter, isA<ZellijAdapter>());
      expect(adapter.id, MultiplexerId.zellij);
    });

    test('herdr', () {
      final adapter = buildMultiplexerAdapter(
        const MultiplexerVerified(
          id: MultiplexerId.herdr,
          absPath: '/home/deployer/.local/bin/herdr',
          onInheritedPath: false,
        ),
        FakeHostCommandRunner(),
      );

      expect(adapter, isA<HerdrAdapter>());
      expect(adapter.id, MultiplexerId.herdr);
    });
  });

  group('buildMultiplexerAdapter — the resolved path reaches the command', () {
    test('attaches through the probe-resolved absolute path', () {
      final adapter = buildMultiplexerAdapter(
        const MultiplexerVerified(
          id: MultiplexerId.tmux,
          absPath: '/opt/homebrew/bin/tmux',
          onInheritedPath: true,
        ),
        FakeHostCommandRunner(),
      );

      expect(adapter.attachCommand('helm-0'), startsWith('/opt/homebrew/bin/tmux'));
    });

    test(
      'attaches an off-inherited-PATH binary by absolute path, so a shell '
      'that cannot resolve the bare name still works',
      () {
        // The verified real-host case: `which herdr` over a non-interactive
        // SSH shell finds nothing, but the binary is at ~/.local/bin/herdr.
        final adapter = buildMultiplexerAdapter(
          const MultiplexerVerified(
            id: MultiplexerId.herdr,
            absPath: '/home/deployer/.local/bin/herdr',
            onInheritedPath: false,
          ),
          FakeHostCommandRunner(),
        );

        expect(
          adapter.attachCommand('helm-0'),
          startsWith('/home/deployer/.local/bin/herdr'),
        );
      },
    );

    test('falls back to the bare binary name when nothing was resolved', () {
      // MultiplexerUnverified carries no path — the probe could not report.
      // Using the bare name is exactly what this code did before the probe
      // existed, so an unverified host is no worse off than before.
      final adapter = buildMultiplexerAdapter(
        const MultiplexerUnverified(id: MultiplexerId.tmux),
        FakeHostCommandRunner(),
      );

      expect(adapter.attachCommand('helm-0'), startsWith('tmux '));
    });

    test('a none-found selection still yields a usable bare-name adapter', () {
      final adapter = buildMultiplexerAdapter(
        const MultiplexerNoneFound(
          requested: MultiplexerId.zellij,
          id: MultiplexerId.zellij,
        ),
        FakeHostCommandRunner(),
      );

      expect(adapter.attachCommand('helm-0'), startsWith('zellij '));
    });
  });

  group('buildMultiplexerAdapter — the session ref reaches the socket', () {
    // The factory is the ONLY place a session ref becomes an agent-scoped
    // adapter. Dropping the argument here would restore the measured
    // failure — `agent list` answering for herdr's DEFAULT session and
    // reporting zero agents while the attached session has a BLOCKED one —
    // and every assertion in herdr_adapter_test.dart would still pass,
    // because that file constructs its adapters directly. So the wiring is
    // pinned here, on the emitted command.
    const herdrSelection = MultiplexerVerified(
      id: MultiplexerId.herdr,
      absPath: '/home/deployer/.local/bin/herdr',
      onInheritedPath: false,
    );

    test('a herdr adapter built with a session ref scopes agent list', () async {
      final runner = FakeHostCommandRunner();
      runner.whenRun(
        "/home/deployer/.local/bin/herdr --session 'helm-0' agent list",
        const HostCommandResult(
          stdout: '{"id":"x","result":{"type":"agent_list","agents":[]}}',
          exitCode: 0,
        ),
      );

      final adapter = buildMultiplexerAdapter(
        herdrSelection,
        runner,
        sessionRef: 'helm-0',
      );
      await (adapter.agents!).listAgents();

      expect(runner.runCalls, [
        "/home/deployer/.local/bin/herdr --session 'helm-0' agent list",
      ]);
    });

    test('a herdr adapter built without one emits no --session flag', () async {
      final runner = FakeHostCommandRunner();
      runner.whenRun(
        '/home/deployer/.local/bin/herdr agent list',
        const HostCommandResult(
          stdout: '{"id":"x","result":{"type":"agent_list","agents":[]}}',
          exitCode: 0,
        ),
      );

      final adapter = buildMultiplexerAdapter(herdrSelection, runner);
      await (adapter.agents!).listAgents();

      expect(runner.runCalls.single, isNot(contains('--session')));
    });

    test(
      'a session ref is harmless for multiplexers that cannot use it — '
      'tmux and zellij take no such flag and must not grow one',
      () {
        for (final id in const [MultiplexerId.tmux, MultiplexerId.zellij]) {
          final adapter = buildMultiplexerAdapter(
            MultiplexerUnverified(id: id),
            FakeHostCommandRunner(),
            sessionRef: 'helm-0',
          );

          expect(adapter.attachCommand('helm-0'), isNot(contains('--session')));
          expect(adapter.agents, isNull);
        }
      },
    );
  });
}
