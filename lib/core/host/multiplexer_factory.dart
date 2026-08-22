import 'package:helm/core/host/adapters/herdr_adapter.dart';
import 'package:helm/core/host/adapters/tmux_adapter.dart';
import 'package:helm/core/host/adapters/zellij_adapter.dart';
import 'package:helm/core/host/host_command_runner.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/multiplexer_selection.dart';

/// Builds the concrete [MultiplexerAdapter] a [MultiplexerSelection] names,
/// bound to [runner].
///
/// Kept out of `multiplexer_selection.dart` on purpose: that file decides
/// WHICH multiplexer to use from host facts alone and imports no adapter,
/// which is what makes it exhaustively testable without a transport. This
/// file is the only place that knows the mapping from an id to a class.
///
/// [MultiplexerSelection.absPath] carries the path the probe resolved. When
/// it is null — the probe could not report, so nothing was resolved — the
/// adapter falls back to the bare binary name, which is byte-for-byte what
/// every attach command looked like before the probe was wired in. When it
/// is non-null the resolved path is used instead, and that is what makes a
/// binary installed off the inherited PATH (the verified
/// `~/.local/bin/herdr` case) attachable at all.
MultiplexerAdapter buildMultiplexerAdapter(
  MultiplexerSelection selection,
  HostCommandRunner runner,
) {
  // Every MultiplexerId's `.name` is exactly the bare binary name, and
  // exactly each adapter's own `absPath` default — so this fallback
  // reproduces the pre-probe default rather than inventing a new one.
  final absPath = selection.absPath ?? selection.id.name;

  return switch (selection.id) {
    MultiplexerId.tmux => TmuxAdapter(runner, absPath: absPath),
    MultiplexerId.zellij => ZellijAdapter(runner, absPath: absPath),
    MultiplexerId.herdr => HerdrAdapter(runner, absPath: absPath),
  };
}
