import 'dart:convert';

import 'package:helm/core/utils/logger.dart';
import 'package:helm/features/shortcuts/domain/project_shortcut.dart';
import 'package:helm/features/shortcuts/domain/quick_action.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists and retrieves shortcuts data using SharedPreferences.
class ShortcutsRepository {
  static final _log = HelmLogger('ShortcutsRepository');
  static const _projectsKey = 'shortcuts_projects';
  static const _quickActionsKey = 'shortcuts_quick_actions';

  // ── Projects ──────────────────────────────────────────────────────────────

  Future<List<ProjectShortcut>> getProjects() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_projectsKey) ?? [];
    return raw
        .map((json) {
          try {
            return ProjectShortcut.fromJson(
              jsonDecode(json) as Map<String, dynamic>,
            );
          } catch (e) {
            _log.e('Failed to deserialize ProjectShortcut', e);
            return null;
          }
        })
        .whereType<ProjectShortcut>()
        .toList();
  }

  Future<void> saveProjects(List<ProjectShortcut> projects) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = projects.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_projectsKey, raw);
    _log.i('Saved ${projects.length} projects');
  }

  // ── Quick Actions ──────────────────────────────────────────────────────────

  Future<List<QuickAction>> getQuickActions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_quickActionsKey) ?? [];
    return raw
        .map((json) {
          try {
            return QuickAction.fromJson(
              jsonDecode(json) as Map<String, dynamic>,
            );
          } catch (e) {
            _log.e('Failed to deserialize QuickAction', e);
            return null;
          }
        })
        .whereType<QuickAction>()
        .toList();
  }

  Future<void> saveQuickActions(List<QuickAction> actions) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = actions.map((a) => jsonEncode(a.toJson())).toList();
    await prefs.setStringList(_quickActionsKey, raw);
    _log.i('Saved ${actions.length} quick actions');
  }
}
