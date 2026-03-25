import 'package:freezed_annotation/freezed_annotation.dart';

part 'quick_action.freezed.dart';
part 'quick_action.g.dart';

/// A quick-action button that sends a predefined command to the active terminal.
@freezed
class QuickAction with _$QuickAction {
  const factory QuickAction({
    /// Unique identifier (UUID v4).
    required String id,

    /// Display label (e.g. "git status").
    required String label,

    /// The command that will be sent to the terminal (e.g. "git status").
    required String command,

    /// Sort order for display in the quick-actions row.
    @Default(0) int sortOrder,
  }) = _QuickAction;

  factory QuickAction.fromJson(Map<String, dynamic> json) =>
      _$QuickActionFromJson(json);
}
