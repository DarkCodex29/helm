import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/settings/presentation/settings_provider.dart';
import 'package:helm/features/shortcuts/data/remote_fs_provider.dart';
import 'package:helm/features/shortcuts/domain/project_shortcut.dart';
import 'package:helm/features/shortcuts/domain/quick_action.dart';
import 'package:helm/features/shortcuts/presentation/shortcuts_provider.dart';
import 'package:helm/features/terminal/presentation/providers/tabs_provider.dart';
import 'package:uuid/uuid.dart';

// ── Project Shortcut Form ──────────────────────────────────────────────────

/// Bottom sheet to create or edit a [ProjectShortcut].
class ProjectShortcutFormSheet extends ConsumerStatefulWidget {
  const ProjectShortcutFormSheet({super.key, this.existing});

  /// When provided, the form is in edit mode.
  final ProjectShortcut? existing;

  @override
  ConsumerState<ProjectShortcutFormSheet> createState() =>
      _ProjectShortcutFormSheetState();
}

class _ProjectShortcutFormSheetState
    extends ConsumerState<ProjectShortcutFormSheet> {
  static const _uuid = Uuid();

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _pathCtrl;
  late final TextEditingController _tmuxCtrl;
  late final TextEditingController _commandCtrl;
  String? _selectedProfileId;

  bool _isLoadingProjects = false;
  bool _isLoadingCurrentDir = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _pathCtrl = TextEditingController(text: e?.projectPath ?? '');
    _tmuxCtrl = TextEditingController(text: e?.tmuxSession ?? '');
    _commandCtrl = TextEditingController(text: e?.command ?? 'opencode');
    _selectedProfileId = e?.profileId;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pathCtrl.dispose();
    _tmuxCtrl.dispose();
    _commandCtrl.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final profileId = _selectedProfileId ?? '';
    if (profileId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a connection profile')),
      );
      return;
    }

    final shortcut = ProjectShortcut(
      id: _isEditing ? widget.existing!.id : _uuid.v4(),
      name: _nameCtrl.text.trim(),
      projectPath: _pathCtrl.text.trim(),
      tmuxSession: _tmuxCtrl.text.trim(),
      command: _commandCtrl.text.trim(),
      profileId: profileId,
      sortOrder: _isEditing ? widget.existing!.sortOrder : 0,
    );

    final notifier = ref.read(shortcutsProvider.notifier);
    if (_isEditing) {
      notifier.updateProject(shortcut);
    } else {
      notifier.addProject(shortcut);
    }
    Navigator.of(context).pop();
  }

  void _delete() {
    if (!_isEditing) return;
    ref.read(shortcutsProvider.notifier).deleteProject(widget.existing!.id);
    Navigator.of(context).pop();
  }

  Future<void> _detectProjects() async {
    final tabsState = ref.read(tabsProvider);
    final activeTab = tabsState.activeTab;

    if (activeTab == null || !activeTab.isConnected) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No hay sesión activa')));
      return;
    }

    final sshClient = activeTab.session.sshClient;
    if (sshClient == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No hay sesión activa')));
      return;
    }

    final remoteFsService = ref.read(remoteFsServiceProvider(sshClient));
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _isLoadingProjects = true);

    try {
      final projects = await remoteFsService.detectProjects();

      if (!mounted) return;
      setState(() => _isLoadingProjects = false);

      if (projects.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('No se encontraron proyectos')),
        );
        return;
      }

      _showProjectPicker(projects);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingProjects = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('No se encontraron proyectos')),
      );
    }
  }

  void _showProjectPicker(List<String> projects) {
    showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Proyectos detectados',
                  style: const TextStyle(
                    color: Color(0xFFE6EDF3),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Divider(color: Color(0xFF30363D), height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: projects.length,
                  itemBuilder: (_, i) {
                    final path = projects[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        path,
                        style: const TextStyle(
                          color: Color(0xFFE6EDF3),
                          fontSize: 13,
                        ),
                      ),
                      onTap: () {
                        Navigator.of(ctx).pop(path);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    ).then((selected) {
      if (selected != null && mounted) {
        setState(() => _pathCtrl.text = selected);
      }
    });
  }

  Future<void> _useCurrentDirectory() async {
    final tabsState = ref.read(tabsProvider);
    final activeTab = tabsState.activeTab;

    if (activeTab == null || !activeTab.isConnected) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No hay sesión activa')));
      return;
    }

    final sshClient = activeTab.session.sshClient;
    if (sshClient == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No hay sesión activa')));
      return;
    }

    final remoteFsService = ref.read(remoteFsServiceProvider(sshClient));
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _isLoadingCurrentDir = true);

    try {
      final dir = await remoteFsService.getCurrentDirectory();

      if (!mounted) return;
      setState(() => _isLoadingCurrentDir = false);

      if (dir == null || dir.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('No se pudo obtener el directorio actual'),
          ),
        );
        return;
      }

      setState(() => _pathCtrl.text = dir);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingCurrentDir = false);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No se pudo obtener el directorio actual'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final profilesAsync = ref.watch(profilesProvider);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF30363D),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  _isEditing ? 'Edit Project' : 'New Project',
                  style: const TextStyle(
                    color: Color(0xFFE6EDF3),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                _FormField(
                  controller: _nameCtrl,
                  label: 'Name',
                  hint: 'Metalpren',
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                _FormField(
                  controller: _pathCtrl,
                  label: 'Project Path',
                  hint: '/home/gian/proyectos/metalpren',
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _isLoadingProjects ? null : _detectProjects,
                      icon: _isLoadingProjects
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Color(0xFF58A6FF),
                              ),
                            )
                          : const Text('🔍', style: TextStyle(fontSize: 13)),
                      label: const Text(
                        'Detectar proyectos',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF58A6FF),
                        ),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _isLoadingCurrentDir
                          ? null
                          : _useCurrentDirectory,
                      icon: _isLoadingCurrentDir
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Color(0xFF58A6FF),
                              ),
                            )
                          : const Text('📂', style: TextStyle(fontSize: 13)),
                      label: const Text(
                        'Dir actual',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF58A6FF),
                        ),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _FormField(
                  controller: _tmuxCtrl,
                  label: 'tmux Session',
                  hint: 'metalpren',
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                _FormField(
                  controller: _commandCtrl,
                  label: 'Command (optional)',
                  hint: 'opencode',
                ),
                const SizedBox(height: 12),
                // Profile dropdown
                profilesAsync.when(
                  loading: () => const SizedBox(
                    height: 48,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => Text(
                    'Error loading profiles: $e',
                    style: const TextStyle(color: Color(0xFFF85149)),
                  ),
                  data: (profiles) => _ProfileDropdown(
                    profiles: profiles,
                    selectedId: _selectedProfileId,
                    onChanged: (id) => setState(() => _selectedProfileId = id),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    if (_isEditing) ...[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _delete,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFF85149),
                            side: const BorderSide(color: Color(0xFFF85149)),
                          ),
                          child: const Text('Delete'),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF58A6FF),
                          foregroundColor: const Color(0xFF0D1117),
                        ),
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Quick Action Form ──────────────────────────────────────────────────────

/// Bottom sheet to create or edit a [QuickAction].
class QuickActionFormSheet extends ConsumerStatefulWidget {
  const QuickActionFormSheet({super.key, this.existing});

  final QuickAction? existing;

  @override
  ConsumerState<QuickActionFormSheet> createState() =>
      _QuickActionFormSheetState();
}

class _QuickActionFormSheetState extends ConsumerState<QuickActionFormSheet> {
  static const _uuid = Uuid();

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _labelCtrl;
  late final TextEditingController _commandCtrl;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _labelCtrl = TextEditingController(text: e?.label ?? '');
    _commandCtrl = TextEditingController(text: e?.command ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _commandCtrl.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final action = QuickAction(
      id: _isEditing ? widget.existing!.id : _uuid.v4(),
      label: _labelCtrl.text.trim(),
      command: _commandCtrl.text.trim(),
      sortOrder: _isEditing ? widget.existing!.sortOrder : 0,
    );

    final notifier = ref.read(shortcutsProvider.notifier);
    if (_isEditing) {
      notifier.updateQuickAction(action);
    } else {
      notifier.addQuickAction(action);
    }
    Navigator.of(context).pop();
  }

  void _delete() {
    if (!_isEditing) return;
    ref.read(shortcutsProvider.notifier).deleteQuickAction(widget.existing!.id);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF30363D),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  _isEditing ? 'Edit Quick Action' : 'New Quick Action',
                  style: const TextStyle(
                    color: Color(0xFFE6EDF3),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                _FormField(
                  controller: _labelCtrl,
                  label: 'Label',
                  hint: 'git status',
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                _FormField(
                  controller: _commandCtrl,
                  label: 'Command',
                  hint: 'git status',
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    if (_isEditing) ...[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _delete,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFF85149),
                            side: const BorderSide(color: Color(0xFFF85149)),
                          ),
                          child: const Text('Delete'),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF58A6FF),
                          foregroundColor: const Color(0xFF0D1117),
                        ),
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Private helpers ────────────────────────────────────────────────────────

class _FormField extends StatelessWidget {
  const _FormField({
    required this.controller,
    required this.label,
    required this.hint,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      validator: validator,
      style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Color(0xFFB1BAC4), fontSize: 13),
        hintStyle: const TextStyle(color: Color(0xFF30363D), fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF21262D),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF30363D)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF30363D)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF58A6FF)),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFF85149)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
    );
  }
}

class _ProfileDropdown extends StatelessWidget {
  const _ProfileDropdown({
    required this.profiles,
    required this.selectedId,
    required this.onChanged,
  });

  final List<ConnectionProfile> profiles;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      // ignore: deprecated_member_use
      value: selectedId,
      hint: const Text(
        'Select connection profile',
        style: TextStyle(color: Color(0xFF8B949E), fontSize: 13),
      ),
      dropdownColor: const Color(0xFF21262D),
      style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 14),
      decoration: InputDecoration(
        labelText: 'Connection Profile',
        labelStyle: const TextStyle(color: Color(0xFFB1BAC4), fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF21262D),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF30363D)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF30363D)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF58A6FF)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
      items: profiles
          .map((p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
          .toList(),
      onChanged: onChanged,
    );
  }
}
