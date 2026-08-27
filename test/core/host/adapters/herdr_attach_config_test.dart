// Tests for the HERDR_CONFIG_PATH prefix on HerdrAdapter.attachCommand.
//
// herdr draws a collapsed sidebar and a tab row inside the terminal. On a
// desktop that is orientation; on a phone it is roughly a sixth of the
// viewport restating what helm's own drawer already shows. herdr reads
// HERDR_CONFIG_PATH to override its config file, so pointing it at a
// host-side mobile config is how that chrome is dropped per client rather
// than globally.
//
// The half that matters most here is the INERT FALLBACK. A host with no
// mobile config, a probe that could not run, and a truncated probe must
// every one of them produce the exact command this adapter emitted before
// this feature existed, byte for byte. A regression there would silently
// change the config on every host — worse than the chrome it removes.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/adapters/herdr_adapter.dart';
import 'package:helm/core/host/shell_quote.dart';

import '../../../helpers/fake_host_command_runner.dart';

void main() {
  const configPath = '/home/deployer/.config/herdr/config.mobile.toml';

  group('HerdrAdapter.attachCommand — no mobile config reported', () {
    test('omitting mobileConfigPath emits the pre-existing command', () {
      final adapter = HerdrAdapter(FakeHostCommandRunner());

      expect(adapter.attachCommand('work'), "herdr session attach 'work'");
    });

    test('an explicit null emits the pre-existing command', () {
      final adapter = HerdrAdapter(
        FakeHostCommandRunner(),
        absPath: '/home/deployer/.local/bin/herdr',
        mobileConfigPath: null,
      );

      expect(
        adapter.attachCommand('work'),
        "/home/deployer/.local/bin/herdr session attach 'work'",
      );
    });

    test('an empty path is treated as absent, never sent', () {
      // Measured against herdr 0.8.2: HERDR_CONFIG_PATH pointing at a
      // nonexistent path does NOT fail — `config check` and `session list`
      // both exit 0 — but whether it falls back to built-in defaults or to
      // the standard config path was never determined. An empty value is
      // therefore never worth the risk of finding out in production.
      final adapter = HerdrAdapter(
        FakeHostCommandRunner(),
        mobileConfigPath: '',
      );

      expect(adapter.attachCommand('work'), "herdr session attach 'work'");
      expect(adapter.attachCommand('work'), isNot(contains('HERDR_CONFIG_PATH')));
    });
  });

  group('HerdrAdapter.attachCommand — mobile config reported', () {
    test('prefixes the assignment through `env`, keeping the same tail', () {
      final adapter = HerdrAdapter(
        FakeHostCommandRunner(),
        absPath: '/home/deployer/.local/bin/herdr',
        mobileConfigPath: configPath,
      );

      expect(
        adapter.attachCommand('work'),
        "env HERDR_CONFIG_PATH='$configPath' "
        "/home/deployer/.local/bin/herdr session attach 'work'",
      );
    });

    test('the tail is byte-identical to the unprefixed command', () {
      // Pins that the prefix is purely additive: whatever the adapter
      // emitted before is still emitted verbatim after it.
      final bare = HerdrAdapter(FakeHostCommandRunner());
      final configured = HerdrAdapter(
        FakeHostCommandRunner(),
        mobileConfigPath: configPath,
      );

      expect(
        configured.attachCommand('work'),
        endsWith(' ${bare.attachCommand('work')}'),
      );
    });

    test('`env` is used because a bare VAR=value prefix breaks csh/tcsh', () {
      // MEASURED locally, both directions:
      //   /bin/csh  -c "FOO=bar printenv FOO"      -> "FOO=bar: Command not found."
      //   /bin/tcsh -c "FOO=bar printenv FOO"      -> "FOO=bar: Command not found."
      //   /bin/csh  -c "env FOO=bar printenv FOO"  -> "bar"
      // The attach runs through client.execute(), so sshd invokes it as
      // `$SHELL -c '<command>'` — and docs/host-contract/v1.md already
      // documents fish/csh login shells as a supported reality. A bare
      // prefix would break the attach outright on those hosts.
      final adapter = HerdrAdapter(
        FakeHostCommandRunner(),
        mobileConfigPath: configPath,
      );

      expect(adapter.attachCommand('work'), startsWith('env HERDR_CONFIG_PATH='));
    });
  });

  group('HerdrAdapter.attachCommand — the path reaches a remote shell', () {
    test('single-quotes a config path containing spaces', () {
      const path = '/home/de ployer/.config/herdr/config.mobile.toml';
      final adapter = HerdrAdapter(
        FakeHostCommandRunner(),
        mobileConfigPath: path,
      );

      expect(
        adapter.attachCommand('work'),
        'env HERDR_CONFIG_PATH=${shellQuote(path)} '
        "herdr session attach 'work'",
      );
    });

    test('single-quotes a config path with a command separator', () {
      const path = '/tmp/x; rm -rf ~';
      final adapter = HerdrAdapter(
        FakeHostCommandRunner(),
        mobileConfigPath: path,
      );

      expect(
        adapter.attachCommand('work'),
        'env HERDR_CONFIG_PATH=${shellQuote(path)} '
        "herdr session attach 'work'",
      );
    });

    test('single-quotes a config path with command substitution', () {
      const path = r'/tmp/$(id)/config.mobile.toml';
      final adapter = HerdrAdapter(
        FakeHostCommandRunner(),
        mobileConfigPath: path,
      );

      expect(
        adapter.attachCommand('work'),
        'env HERDR_CONFIG_PATH=${shellQuote(path)} '
        "herdr session attach 'work'",
      );
    });

    test('single-quotes a config path with an embedded single quote', () {
      // A home directory can genuinely contain one, and the `'\''` idiom
      // shellQuote implements is the only correct escape inside a
      // single-quoted POSIX string.
      const path = "/home/O'Brien/.config/herdr/config.mobile.toml";
      final adapter = HerdrAdapter(
        FakeHostCommandRunner(),
        mobileConfigPath: path,
      );

      expect(
        adapter.attachCommand('work'),
        'env HERDR_CONFIG_PATH=${shellQuote(path)} '
        "herdr session attach 'work'",
      );
    });

    test('the session name stays quoted independently of the prefix', () {
      const name = 'x; rm -rf ~';
      final adapter = HerdrAdapter(
        FakeHostCommandRunner(),
        mobileConfigPath: configPath,
      );

      expect(adapter.attachCommand(name), endsWith(shellQuote(name)));
    });
  });
}
