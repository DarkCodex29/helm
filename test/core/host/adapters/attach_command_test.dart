import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/adapters/tmux_adapter.dart';
import 'package:helm/core/host/shell_quote.dart';

import '../../../helpers/fake_host_command_runner.dart';

// AD-3: attachCommand single-quotes the session name because session names
// are user-controlled and reach a remote shell. This is a pure function —
// no SSH involved — so every case here is a plain value assertion.
void main() {
  group('TmuxAdapter.attachCommand', () {
    late TmuxAdapter adapter;

    setUp(() {
      adapter = TmuxAdapter(
        FakeHostCommandRunner(),
        absPath: '/opt/homebrew/bin/tmux',
      );
    });

    test('uses the resolved absolute path, not a bare binary name', () {
      expect(
        adapter.attachCommand('work'),
        "/opt/homebrew/bin/tmux new-session -A -s 'work'",
      );
    });

    test('is idempotent: attach-or-create via -A', () {
      expect(adapter.attachCommand('work'), contains('new-session -A -s'));
    });

    test('single-quotes a session name with a shell command separator', () {
      const name = 'x; rm -rf ~';
      expect(
        adapter.attachCommand(name),
        '/opt/homebrew/bin/tmux new-session -A -s ${shellQuote(name)}',
      );
    });

    test('single-quotes a session name with command substitution', () {
      const name = r'$(id)';
      expect(
        adapter.attachCommand(name),
        '/opt/homebrew/bin/tmux new-session -A -s ${shellQuote(name)}',
      );
    });

    test('single-quotes a session name with backticks', () {
      const name = '`id`';
      expect(
        adapter.attachCommand(name),
        '/opt/homebrew/bin/tmux new-session -A -s ${shellQuote(name)}',
      );
    });

    test('single-quotes a session name with an embedded single quote', () {
      const name = "O'Brien";
      expect(
        adapter.attachCommand(name),
        '/opt/homebrew/bin/tmux new-session -A -s ${shellQuote(name)}',
      );
    });

    test('single-quotes a session name with a leading dash', () {
      const name = '-rf';
      expect(
        adapter.attachCommand(name),
        '/opt/homebrew/bin/tmux new-session -A -s ${shellQuote(name)}',
      );
    });

    test(
      'falls back to the bare binary name when no absolute path is resolved',
      () {
        final bareAdapter = TmuxAdapter(FakeHostCommandRunner());

        expect(
          bareAdapter.attachCommand('work'),
          "tmux new-session -A -s 'work'",
        );
      },
    );
  });
}
