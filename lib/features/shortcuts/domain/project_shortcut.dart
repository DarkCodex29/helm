import 'package:freezed_annotation/freezed_annotation.dart';

part 'project_shortcut.freezed.dart';
part 'project_shortcut.g.dart';

/// A project shortcut that opens a terminal in a specific directory
/// with a named tmux session and optional command.
@freezed
class ProjectShortcut with _$ProjectShortcut {
  const factory ProjectShortcut({
    /// Unique identifier (UUID v4).
    required String id,

    /// Human-readable name (e.g. "Metalpren").
    required String name,

    /// Absolute path on the remote machine (e.g. "/home/gian/proyectos/metalpren").
    required String projectPath,

    /// tmux session name to attach to or create (e.g. "metalpren").
    required String tmuxSession,

    /// Command to run after navigating to [projectPath] (e.g. "opencode").
    /// Empty string means no command is run.
    @Default('') String command,

    /// ID of the [ConnectionProfile] to use.
    required String profileId,

    /// Sort order for display in the sidebar.
    @Default(0) int sortOrder,
  }) = _ProjectShortcut;

  factory ProjectShortcut.fromJson(Map<String, dynamic> json) =>
      _$ProjectShortcutFromJson(json);
}
