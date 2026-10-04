import 'package:flutter/material.dart';
import 'package:helm/core/theme/app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/core/constants/app_constants.dart';
import 'package:helm/core/host/multiplexer_adapter.dart';
import 'package:helm/core/host/session_reference.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/data/ssh_service.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/settings/presentation/settings_provider.dart';
import 'package:helm/features/settings/presentation/terminal_font_size_preview.dart';
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
  final _sessionRefCtrl = TextEditingController();

  bool _isDefault = false;
  bool _holdInBackground = false;
  double _fontSize = AppConstants.defaultTerminalFontSize;
  bool _isSaving = false;
  String? _testStatus;
  bool _testPassed = false;

  /// `null` means "host default multiplexer" — see
  /// `lib/core/host/multiplexer_adapter.dart`.
  MultiplexerId? _selectedMultiplexer;

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
        // profile.sessionRef already resolves the legacy/neutral
        // precedence at load time (see connection_profile.dart's
        // _readSessionRef) — no fallback needed here.
        _sessionRefCtrl.text = profile.sessionRef ?? '';
        _selectedMultiplexer = decodeMultiplexer(profile.multiplexer);
        _isDefault = profile.isDefault;
        _holdInBackground = profile.holdInBackground;
        _fontSize = profile.fontSize;
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _sessionRefCtrl.dispose();
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
              hint: 'Production Server',
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
              controller: _sessionRefCtrl,
              label: 'Session reference (optional)',
              hint: 'helm',
              prefixIcon: Icons.terminal,
            ),
            const SizedBox(height: 12),
            _MultiplexerDropdown(
              selected: _selectedMultiplexer,
              onChanged: (id) => setState(() => _selectedMultiplexer = id),
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
            const SizedBox(height: 12),
            // Beside "Set as default profile" rather than in a section of
            // its own: both answer "what should helm do by itself for this
            // machine?", and both are things the user sets once. A second
            // pattern for the same kind of setting would only make the
            // pair harder to read.
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.outline),
              ),
              child: Semantics(
                identifier: ProfileEditSemantics.backgroundHoldSwitch,
                child: SwitchListTile(
                  title: Text(
                    'Hold this session in the background',
                    style: theme.textTheme.bodyMedium,
                  ),
                  // Says what it starts, what the user will see, what it
                  // costs and how to stop it. Deliberately not "stay
                  // connected": that names the benefit and hides the
                  // price, and a switch whose price is a permanent
                  // notification and battery drain has to state both for
                  // the tap to be an informed one — which is exactly what
                  // makes it the user-initiated action a foreground
                  // service is allowed to be started by.
                  subtitle: Text(
                    'Runs a background service with an ongoing notification '
                    'on every connect, so the session survives while you are '
                    'in other apps. Costs battery; stop it any time from that '
                    'notification or the toolbar pin.',
                    style: theme.textTheme.bodySmall,
                  ),
                  isThreeLine: true,
                  value: _holdInBackground,
                  onChanged: (v) => setState(() => _holdInBackground = v),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _FontSizeControl(
              value: _fontSize,
              onChanged: (v) => setState(() => _fontSize = v),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: Semantics(
                identifier: ProfileEditSemantics.testConnectionButton,
                child: OutlinedButton.icon(
                  onPressed: _isSaving ? null : _testConnection,
                  icon: const Icon(Icons.wifi_tethering, size: 18),
                  label: const Text('Test Connection'),
                ),
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
    // Mirror the session reference into the legacy field — see
    // lib/core/host/session_reference.dart for why this is the sole
    // mirroring point rather than re-derived here.
    final resolvedSessionRef = resolveOptionalSessionReference(
      _sessionRefCtrl.text,
    );
    final profile = ConnectionProfile(
      id: _loadedProfile?.id ?? _uuid.v4(),
      name: _nameCtrl.text.trim(),
      host: _hostCtrl.text.trim(),
      port: int.parse(_portCtrl.text.trim()),
      username: _userCtrl.text.trim(),
      tmuxSession: resolvedSessionRef.legacyValue,
      sessionRef: resolvedSessionRef.sessionRef,
      multiplexer: encodeMultiplexer(_selectedMultiplexer),
      isDefault: _isDefault,
      holdInBackground: _holdInBackground,
      fontSize: _fontSize,
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

/// Lets the user pick which multiplexer [ConnectionProfile.sessionRef]
/// applies to. `null` means "host default" — this screen never probes
/// the host, so no option is disabled or flagged based on what the host
/// actually has installed; that check happens elsewhere at attach time.
class _MultiplexerDropdown extends StatelessWidget {
  const _MultiplexerDropdown({required this.selected, required this.onChanged});

  final MultiplexerId? selected;
  final ValueChanged<MultiplexerId?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: ProfileEditSemantics.multiplexerDropdown,
      child: DropdownButtonFormField<MultiplexerId?>(
        // ignore: deprecated_member_use
        value: selected,
        decoration: const InputDecoration(
          labelText: 'Multiplexer (optional)',
          prefixIcon: Icon(Icons.dashboard_customize_outlined, size: 18),
        ),
        items: [
          const DropdownMenuItem(value: null, child: Text('Host default')),
          ...MultiplexerId.values.map(
            (id) => DropdownMenuItem(value: id, child: Text(id.name)),
          ),
        ],
        onChanged: onChanged,
      ),
    );
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
            success ? AppTheme.successIcon : AppTheme.errorIcon,
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

/// Lets the user pick [ConnectionProfile.fontSize] by what it buys rather
/// than by its point size alone: each candidate is labelled with the
/// LIVE column count `previewColumnsForFontSize` measures for it at this
/// control's own on-screen width.
///
/// The width is the SCREEN's, and that choice was wrong here until it was
/// measured. This control previously used its own [LayoutBuilder]
/// constraints, reasoning that the terminal sits inside the same Scaffold
/// and must therefore be narrower than the full screen. Measured on a
/// Samsung S22 Ultra on 2026-10-04, that reasoning was backwards: the
/// preview announced **~39 columns at 13pt while the PTY the terminal
/// actually negotiated was 49** — read from the host with `stty -f
/// /dev/ttysNNN size` against the session that phone had just opened.
///
/// The cause is that this control is not the terminal. It sits inside the
/// editor's page padding AND its own card padding, roughly 40dp a side,
/// so its constraints describe a box about 80% as wide as the terminal.
/// `HelmTerminalView` is a direct child of an `Expanded` with no
/// horizontal padding at all (`home_screen.dart:279-280`), so the screen
/// width is the honest approximation and the card's width never was.
///
/// The error was systematic rather than noisy, which is what made it
/// findable: 49/39 is 1.256, and applying that to the 8pt chip's old ~64
/// lands on ~80, matching an earlier device reading of 81 columns at 8pt.
///
/// This is still an approximation. The ACTUAL viewport only ever comes
/// from `TerminalView`'s real layout once a session exists (see
/// `terminal_view_widget.dart`); this preview exists to inform the choice
/// before a session does.
class _FontSizeControl extends StatelessWidget {
  const _FontSizeControl({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      identifier: ProfileEditSemantics.fontSizeControl,
      container: true,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.colorScheme.outline),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Terminal text size', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              'Smaller text fits more columns, which matters for TUIs '
              'that paint a fixed 80-column layout - the estimate below '
              'is for the terminal on this device.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: AppConstants.terminalFontSizeOptions.map((size) {
                final columns = previewColumnsForFontSize(
                  fontSize: size,
                  viewportWidth: MediaQuery.sizeOf(context).width,
                );
                final selected = size == value;
                return Semantics(
                  identifier: ProfileEditSemantics.fontSizeOption(size.round()),
                  child: ChoiceChip(
                    label: Text('${size.round()}pt - ~$columns cols'),
                    selected: selected,
                    onSelected: (_) => onChanged(size),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
