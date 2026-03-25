import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/shortcuts/data/shortcuts_repository.dart';
import 'package:helm/features/shortcuts/domain/project_shortcut.dart';
import 'package:helm/features/shortcuts/domain/quick_action.dart';

// ── Repository provider ────────────────────────────────────────────────────

final shortcutsRepoProvider = Provider<ShortcutsRepository>(
  (_) => ShortcutsRepository(),
);

// ── State ──────────────────────────────────────────────────────────────────

class ShortcutsState {
  const ShortcutsState({
    this.projects = const [],
    this.quickActions = const [],
  });

  final List<ProjectShortcut> projects;
  final List<QuickAction> quickActions;

  ShortcutsState copyWith({
    List<ProjectShortcut>? projects,
    List<QuickAction>? quickActions,
  }) {
    return ShortcutsState(
      projects: projects ?? this.projects,
      quickActions: quickActions ?? this.quickActions,
    );
  }
}

// ── Notifier ───────────────────────────────────────────────────────────────

class ShortcutsNotifier extends Notifier<ShortcutsState> {
  @override
  ShortcutsState build() {
    // Load async without blocking — returns empty state immediately.
    Future.microtask(() => loadAll());
    return const ShortcutsState();
  }

  ShortcutsRepository get _repo => ref.read(shortcutsRepoProvider);

  Future<void> loadAll() async {
    final projects = await _repo.getProjects();
    final quickActions = await _repo.getQuickActions();
    state = state.copyWith(projects: projects, quickActions: quickActions);
  }

  // ── Projects ─────────────────────────────────────────────────────────────

  Future<void> addProject(ProjectShortcut project) async {
    final updated = [...state.projects, project];
    state = state.copyWith(projects: updated);
    await _repo.saveProjects(updated);
  }

  Future<void> updateProject(ProjectShortcut project) async {
    final updated = state.projects
        .map((p) => p.id == project.id ? project : p)
        .toList();
    state = state.copyWith(projects: updated);
    await _repo.saveProjects(updated);
  }

  Future<void> deleteProject(String id) async {
    final updated = state.projects.where((p) => p.id != id).toList();
    state = state.copyWith(projects: updated);
    await _repo.saveProjects(updated);
  }

  Future<void> reorderProjects(int oldIndex, int newIndex) async {
    final list = [...state.projects];
    if (oldIndex < newIndex) newIndex -= 1;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    // Update sortOrder to match new position.
    final reordered = list
        .asMap()
        .entries
        .map((e) => e.value.copyWith(sortOrder: e.key))
        .toList();
    state = state.copyWith(projects: reordered);
    await _repo.saveProjects(reordered);
  }

  // ── Quick Actions ─────────────────────────────────────────────────────────

  Future<void> addQuickAction(QuickAction action) async {
    final updated = [...state.quickActions, action];
    state = state.copyWith(quickActions: updated);
    await _repo.saveQuickActions(updated);
  }

  Future<void> updateQuickAction(QuickAction action) async {
    final updated = state.quickActions
        .map((a) => a.id == action.id ? action : a)
        .toList();
    state = state.copyWith(quickActions: updated);
    await _repo.saveQuickActions(updated);
  }

  Future<void> deleteQuickAction(String id) async {
    final updated = state.quickActions.where((a) => a.id != id).toList();
    state = state.copyWith(quickActions: updated);
    await _repo.saveQuickActions(updated);
  }
}

// ── Provider ───────────────────────────────────────────────────────────────

final shortcutsProvider = NotifierProvider<ShortcutsNotifier, ShortcutsState>(
  ShortcutsNotifier.new,
);
