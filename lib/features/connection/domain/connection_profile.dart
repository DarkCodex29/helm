import 'package:freezed_annotation/freezed_annotation.dart';

part 'connection_profile.freezed.dart';
part 'connection_profile.g.dart';

/// Represents a saved SSH connection configuration.
@freezed
class ConnectionProfile with _$ConnectionProfile {
  const factory ConnectionProfile({
    /// Unique identifier (UUID v4).
    required String id,

    /// Human-readable name for this profile (e.g. "Mac Studio").
    required String name,

    /// Hostname or IP address of the remote machine.
    required String host,

    /// SSH port — defaults to 22.
    @Default(22) int port,

    /// SSH username on the remote machine.
    required String username,

    /// Optional custom tmux session name. Falls back to AppConstants.defaultTmuxSession.
    String? tmuxSession,

    /// Whether this is the default profile to connect to on launch.
    @Default(false) bool isDefault,
  }) = _ConnectionProfile;

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) =>
      _$ConnectionProfileFromJson(json);
}
