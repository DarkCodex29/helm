import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:helm/features/auth/domain/auth_state.dart';
import 'package:helm/features/auth/presentation/auth_provider.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _authenticate();
    });
  }

  Future<void> _authenticate() async {
    await ref.read(authProvider.notifier).authenticate();
  }

  @override
  Widget build(BuildContext context) {
    final authAsync = ref.watch(authProvider);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _HelmLogo(),
                const SizedBox(height: 40),
                Text(
                  'Helm',
                  style: theme.textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'SSH Terminal',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 48),
                authAsync.when(
                  data: (state) => _buildSubtitle(context, state),
                  loading: () => Text(
                    'Authenticating…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  error: (e, _) => Text(
                    'Something went wrong',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                authAsync.when(
                  data: (state) => _buildButton(context, state),
                  loading: () => SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  error: (e, _) => _retryButton(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubtitle(BuildContext context, AuthState state) {
    final theme = Theme.of(context);
    final text = switch (state) {
      AuthState.locked => 'Authenticate to continue',
      AuthState.unlocked => 'Authenticated ✓',
      AuthState.unavailable => 'No biometrics available',
      AuthState.initial => 'Preparing…',
    };
    final color = state == AuthState.unlocked
        ? theme.colorScheme.secondary
        : theme.colorScheme.onSurface.withValues(alpha: 0.7);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(color: color),
      textAlign: TextAlign.center,
    );
  }

  Widget _buildButton(BuildContext context, AuthState state) {
    return switch (state) {
      AuthState.locked => _retryButton(context),
      AuthState.unlocked => const SizedBox.shrink(),
      AuthState.unavailable => const SizedBox.shrink(),
      AuthState.initial => const SizedBox.shrink(),
    };
  }

  Widget _retryButton(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: _authenticate,
      icon: const Icon(Icons.fingerprint, size: 20),
      label: const Text('Authenticate'),
    );
  }
}

class _HelmLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.25),
            theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
          ],
        ),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.2),
            blurRadius: 32,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Icon(Icons.terminal, size: 52, color: theme.colorScheme.primary),
    );
  }
}
