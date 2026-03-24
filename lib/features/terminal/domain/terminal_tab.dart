import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/data/terminal_session.dart';

/// Represents a single terminal tab — one SSH session with its own xterm.
class TerminalTab {
  TerminalTab({
    required this.id,
    required this.title,
    required this.session,
    required this.profile,
  });

  /// Unique identifier for this tab (UUID).
  final String id;

  /// Display title shown in the tab strip.
  String title;

  /// The underlying SSH ↔ xterm bridge.
  final TerminalSession session;

  /// The connection profile used for this tab.
  final ConnectionProfile profile;

  /// Whether the SSH session is currently active.
  bool get isConnected => session.isConnected;
}
