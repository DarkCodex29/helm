import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/settings/presentation/settings_provider.dart';
import 'package:uuid/uuid.dart';

class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key, this.profileId});

  final String? profileId;

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  static const _uuid = Uuid();

  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(
    text: '${AppConstants.defaultSshPort}',
  );
  final _userCtrl = TextEditingController();
  final _tmuxCtrl = TextEditingController();

  bool _isDefault = false;
  bool _isSaving = false;
  String? _testStatus;
  bool _testPassed = false;

  ConnectionProfile? _loadedProfile;

  @override
  void initState() {
    super.initState();
    if (widget.profileId != null) {
      _loadProfile();
    }
  }

  Future<void> _loadProfile() async {
    final repo = ConnectionProfileRepository();
    final profile = await repo.getById(widget.profileId!);
    if (profile != null && mounted) {
      setState(() {
        _loadedProfile = profile;
        _nameCtrl.text = profile.name;
        _hostCtrl.text = profile.host;
        _portCtrl.text = '${profile.port}';
        _userCtrl.text = profile.username;
        _tmuxCtrl.text = profile.tmuxSession ?? '';
        _isDefault = profile.isDefault;
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _tmuxCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.profileId == null;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'New Profile' : 'Edit Profile'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.pop(),
        ),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  )
                : Text(
                    'Save',
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _buildSectionLabel(context, 'Profile'),
            const SizedBox(height: 8),
            _buildTextField(
              controller: _nameCtrl,
              label: 'Name',
              hint: 'Mac Studio',
              prefixIcon: Icons.label_outline,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name is required' : null,
            ),
            const SizedBox(height: 20),
            _buildSectionLabel(context, 'Connection'),
            const SizedBox(height: 8),
            _buildTextField(
              controller: _hostCtrl,
              label: 'Host',
              hint: '192.168.1.100 or hostname',
              prefixIcon: Icons.dns_outlined,
              keyboardType: TextInputType.url,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Host is required' : null,
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: _buildTextField(
                    controller: _userCtrl,
                    label: 'Username',
                    hint: 'gian',
                    prefixIcon: Icons.person_outline,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Username is required'
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildTextField(
                    controller: _portCtrl,
                    label: 'Port',
                    hint: '22',
                    prefixIcon: Icons.settings_ethernet,
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final port = int.tryParse(v ?? '');
                      if (port == null || port < 1 || port > 65535) {
                        return '1–65535';
                      }
                      return null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildSectionLabel(context, 'Advanced'),
            const SizedBox(height: 8),
            _buildTextField(
              controller: _tmuxCtrl,
              label: 'tmux session (optional)',
              hint: 'helm',
              prefixIcon: Icons.terminal,
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.outline),
              ),
              child: SwitchListTile(
                title: Text(
                  'Set as default profile',
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  'Opens automatically on launch',
                  style: theme.textTheme.bodySmall,
                ),
                value: _isDefault,
                onChanged: (v) => setState(() => _isDefault = v),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isSaving ? null : _testConnection,
                icon: const Icon(Icons.wifi_tethering, size: 18),
                label: const Text('Test Connection'),
              ),
            ),
            if (_testStatus != null) ...[
              const SizedBox(height: 12),
              _TestStatusCard(message: _testStatus!, success: _testPassed),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionLabel(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Text(
      label.toUpperCase(),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.primary.withValues(alpha: 0.8),
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
        fontSize: 10,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    String? hint,
    IconData? prefixIcon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 18) : null,
      ),
      validator: validator,
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isSaving = true);

    final repo = ConnectionProfileRepository();
    final profile = ConnectionProfile(
      id: _loadedProfile?.id ?? _uuid.v4(),
      name: _nameCtrl.text.trim(),
      host: _hostCtrl.text.trim(),
      port: int.parse(_portCtrl.text.trim()),
      username: _userCtrl.text.trim(),
      tmuxSession: _tmuxCtrl.text.trim().isEmpty ? null : _tmuxCtrl.text.trim(),
      isDefault: _isDefault,
    );

    try {
      if (_loadedProfile != null) {
        await repo.update(profile);
      } else {
        await repo.create(profile);
      }

      if (_isDefault) {
        await repo.setDefault(profile.id);
      }

      ref.invalidate(profilesProvider);

      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _testConnection() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isSaving = true;
      _testStatus = 'Testing connection…';
      _testPassed = false;
    });

    try {
      final keyService = SSHKeyService();
      final privateKey = await keyService.getPrivateKey();

      if (privateKey == null) {
        setState(() {
          _testStatus = 'No SSH key found. Generate a key first.';
          _testPassed = false;
        });
        return;
      }

      final profile = ConnectionProfile(
        id: 'test',
        name: _nameCtrl.text.trim(),
        host: _hostCtrl.text.trim(),
        port: int.parse(_portCtrl.text.trim()),
        username: _userCtrl.text.trim(),
      );

      final sshService = SSHService();
      final result = await sshService.connectAndOpenShell(profile, privateKey);
      await sshService.disconnect(result.client);

      setState(() {
        _testStatus = 'Connection successful!';
        _testPassed = true;
      });
    } catch (e) {
      setState(() {
        _testStatus = SSHService.describeError(e);
        _testPassed = false;
      });
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}

class _TestStatusCard extends StatelessWidget {
  const _TestStatusCard({required this.message, required this.success});
  final String message;
  final bool success;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = success
        ? theme.colorScheme.secondary
        : theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            success ? Icons.check_circle_outline : Icons.error_outline,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
