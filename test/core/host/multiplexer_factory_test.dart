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
}
