import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/connection/data/ssh_key_service.dart';
import 'package:helm/features/connection/data/connection_profile_repository.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';

final _sshKeyServiceProvider = Provider((_) => SSHKeyService());
final _repoProvider = Provider((_) => ConnectionProfileRepository());

class FirstTimeSetupScreen extends ConsumerStatefulWidget {
  const FirstTimeSetupScreen({super.key});

  @override
  ConsumerState<FirstTimeSetupScreen> createState() =>
      _FirstTimeSetupScreenState();
}

class _FirstTimeSetupScreenState extends ConsumerState<FirstTimeSetupScreen> {
  String? _publicKey;
  bool _generatingKey = false;
  bool _keyGenerated = false;

  final _hostController = TextEditingController();
  final _usernameController = TextEditingController();
  final _profileNameController = TextEditingController(text: 'My Mac');
  final _portController = TextEditingController(text: '22');

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _generateKey();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _usernameController.dispose();
    _profileNameController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _generateKey() async {
    setState(() => _generatingKey = true);
    try {
      final keyService = ref.read(_sshKeyServiceProvider);
      if (!await keyService.hasKeyPair()) {
        await keyService.generateAndSave();
      }
      final pubKey = await keyService.getPublicKey();
      setState(() {
        _publicKey = pubKey;
        _keyGenerated = true;
        _generatingKey = false;
      });
    } catch (e) {
      setState(() => _generatingKey = false);
    }
  }

  Future<void> _copyPublicKey() async {
    if (_publicKey == null) return;
    await Clipboard.setData(ClipboardData(text: _publicKey!));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Public key copied!')));
    }
  }

  Future<void> _saveAndContinue() async {
    final host = _hostController.text.trim();
    final username = _usernameController.text.trim();
    final name = _profileNameController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 22;

    if (host.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in host and username')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final repo = ref.read(_repoProvider);
      await repo.create(
        ConnectionProfile(
          id: '',
          name: name.isEmpty ? 'My Mac' : name,
          host: host,
          port: port,
          username: username,
          isDefault: true,
        ),
      );
      if (mounted) context.go('/home');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Setup')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StepHeader(
                step: 1,
                title: 'SSH Key',
                subtitle:
                    'Helm uses a passwordless Ed25519 key to connect to your Mac. '
                    'Copy the public key below and add it to your Mac\'s '
                    '~/.ssh/authorized_keys file.',
              ),
              const SizedBox(height: 16),
              if (_generatingKey)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_publicKey != null) ...[
                _SshKeyDisplay(publicKey: _publicKey!, onCopy: _copyPublicKey),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outline),
                  ),
                  child: Text(
                    'echo "<key>" >> ~/.ssh/authorized_keys',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 36),
              _StepHeader(
                step: 2,
                title: 'Connection Details',
                subtitle: 'Enter the details to connect to your Mac.',
              ),
              const SizedBox(height: 16),
              Semantics(
                identifier: SetupSemantics.profileNameField,
                child: TextField(
                  controller: _profileNameController,
                  decoration: const InputDecoration(
                    labelText: 'Profile Name',
                    hintText: 'e.g. Mac Studio',
                    prefixIcon: Icon(Icons.label_outline, size: 18),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Semantics(
                      identifier: SetupSemantics.hostField,
                      child: TextField(
                        controller: _hostController,
                        decoration: const InputDecoration(
                          labelText: 'Host / IP',
                          hintText: '192.168.1.10',
                          prefixIcon: Icon(Icons.dns_outlined, size: 18),
                        ),
                        keyboardType: TextInputType.text,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Semantics(
                      identifier: SetupSemantics.portField,
                      child: TextField(
                        controller: _portController,
                        decoration: const InputDecoration(labelText: 'Port'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Semantics(
                identifier: SetupSemantics.usernameField,
                child: TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    hintText: 'e.g. john',
                    prefixIcon: Icon(Icons.person_outline, size: 18),
                  ),
                ),
              ),
              const SizedBox(height: 36),
              SizedBox(
                width: double.infinity,
                child: Semantics(
                  identifier: SetupSemantics.saveButton,
                  child: ElevatedButton(
                    onPressed: (_keyGenerated && !_isSaving)
                        ? _saveAndContinue
                        : null,
                    child: _isSaving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save and Continue'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({
    required this.step,
    required this.title,
    required this.subtitle,
  });

  final int step;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text(
                '$step',
                style: const TextStyle(
                  color: Color(0xFF0D1117),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(title, style: theme.textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 8),
        Text(subtitle, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _SshKeyDisplay extends StatelessWidget {
  const _SshKeyDisplay({required this.publicKey, required this.onCopy});
  final String publicKey;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(9),
              ),
              border: Border(
                bottom: BorderSide(color: theme.colorScheme.outline),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'public key  (ed25519)',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                Semantics(
                  identifier: SetupSemantics.copyPublicKeyButton,
                  button: true,
                  label: 'Copy public key',
                  child: GestureDetector(
                    onTap: onCopy,
                    child: Icon(
                      Icons.copy,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Semantics(
              identifier: SetupSemantics.publicKeyText,
              child: SelectableText(
                publicKey,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Color(0xFFB1BAC4),
                  height: 1.5,
                ),
                maxLines: 4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
