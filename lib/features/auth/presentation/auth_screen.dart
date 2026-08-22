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
  /// Latches the automatic prompt to the first locked resolution per mount.
  ///
  /// [AuthNotifier.authenticate] emits `AsyncLoading` and then, on failure,
  /// `AsyncData(locked)` again — so a listener that reacted to every locked
  /// emission would prompt forever. Latching breaks that cycle; the manual
  /// retry button calls [_authenticate] directly and is unaffected.
  bool _promptedOnce = false;

  @override
  void initState() {
    super.initState();
    // Prompting unconditionally from here races the notifier, which has not
    // yet resolved whether biometrics exist. When they do not, the native
    // dialog falls back to the device passcode and wins the race against the
    // router's `unavailable` redirect, leaving no way into the app.
    //
    // `listenManual` is the right tool: unlike `ref.listen` it is valid
    // outside `build`, it auto-disposes with this State, and
    // `fireImmediately` also covers a mount onto an already-resolved
    // notifier (the router reads it first, and `lock()` can re-emit while
    // this screen is unmounted).
    ref.listenManual<AsyncValue<AuthState>>(
      authProvider,
      _onAuthStateChanged,
      fireImmediately: true,
    );
  }

  void _onAuthStateChanged(
    AsyncValue<AuthState>? previous,
    AsyncValue<AuthState> next,
  ) {
    if (_promptedOnce) return;
    if (next.valueOrNull != AuthState.locked) return;
    _promptedOnce = true;
    // Latch synchronously, prompt asynchronously. When `fireImmediately`
    // delivers an already-resolved notifier this runs inside `initState`, and
    // `authenticate()` emits `AsyncLoading` — Riverpod rejects that as
    // "modify a provider while the widget tree was building". A microtask
    // drains once the synchronous build scope unwinds, which is the smallest
    // deferral that clears it.
    Future.microtask(() {
      if (mounted) _authenticate();
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _HelmLogo(),
              const SizedBox(height: 24),
              Text(
                'Helm',
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'SSH Terminal',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 32),
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
              const SizedBox(height: 20),
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
      child: Icon(Icons.terminal, size: 40, color: theme.colorScheme.primary),
    );
  }
}
