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
/// [sessionRef] is the multiplexer session the caller is attaching to, when
/// it has one. Only herdr uses it, and only to scope its socket-backed
/// agent queries — see [HerdrAdapter]'s `_sessionRef`, which documents the
/// measured reason a bare `agent list` answers for the WRONG session. tmux
/// and zellij take their session per-command, so they ignore it.
/// to that adapter alone rather than to every adapter that happens to be
/// built here. Null, the default, leaves every attach command byte-for-
/// byte what it was before this existed.
MultiplexerAdapter buildMultiplexerAdapter(
  MultiplexerSelection selection,
  HostCommandRunner runner, {
  String? sessionRef,
}) {
  // Every MultiplexerId's `.name` is exactly the bare binary name, and
  // exactly each adapter's own `absPath` default — so this fallback
  // reproduces the pre-probe default rather than inventing a new one.
  final absPath = selection.absPath ?? selection.id.name;

  return switch (selection.id) {
    MultiplexerId.tmux => TmuxAdapter(runner, absPath: absPath),
    MultiplexerId.zellij => ZellijAdapter(runner, absPath: absPath),
    MultiplexerId.herdr => HerdrAdapter(
      runner,
      absPath: absPath,
      sessionRef: sessionRef,
    ),
  };
}
