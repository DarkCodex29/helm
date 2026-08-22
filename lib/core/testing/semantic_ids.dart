/// Stable semantic identifiers for end-to-end test targeting.
///
/// Every value here is wrapped around a widget with
/// `Semantics(identifier: ...)`. Flutter forwards that identifier to the
/// platform accessibility layer: on Android it becomes the node's
/// `resource-id`, on iOS its accessibility identifier. That is what lets
/// the Maestro flows under `maestro/flows/` address a widget by name
/// instead of by screen coordinates, so a layout change no longer
/// silently breaks the suite.
///
/// Rules for this file:
///
/// * It is the ONLY place these strings are written. The Dart widgets and
///   the Maestro YAML both read the same value, so the two sides cannot
///   drift apart without this file changing.
/// * Values are namespaced `helm.<screen>.<element>`. The `helm.` prefix
///   keeps them distinguishable from framework-generated ids in a view
///   hierarchy dump.
/// * A value is part of the test contract. Renaming one is a breaking
///   change for `maestro/flows/` and both sides must move together.
///
/// These identifiers carry no user-visible text and are not a substitute
/// for a semantic label: they are addressing, not accessibility copy.
library;

/// Identifiers on `FirstTimeSetupScreen`.
class SetupSemantics {
  const SetupSemantics._();

  static const publicKeyText = 'helm.setup.public_key_text';
  static const copyPublicKeyButton = 'helm.setup.copy_public_key_button';
  static const profileNameField = 'helm.setup.profile_name_field';
  static const hostField = 'helm.setup.host_field';
  static const portField = 'helm.setup.port_field';
  static const usernameField = 'helm.setup.username_field';
  static const saveButton = 'helm.setup.save_button';
}

/// Identifiers on `HomeScreen`.
class HomeSemantics {
  const HomeSemantics._();

  /// The hamburger that opens the shortcuts drawer.
  static const drawerButton = 'helm.home.drawer_button';

  /// The AppBar `+` action, only present while there are no tabs.
  static const appBarNewSessionButton = 'helm.home.app_bar_new_session_button';

  /// The large call to action in the empty state.
  static const newSessionButton = 'helm.home.new_session_button';
}

/// Identifiers on `HelmTerminalView`.
class TerminalSemantics {
  const TerminalSemantics._();

  /// The overlay shown whenever the session is not connected. Its
  /// presence is the assertion target for connection-failure flows.
  static const connectionStatusOverlay =
      'helm.terminal.connection_status_overlay';
  static const reconnectButton = 'helm.terminal.reconnect_button';
}

/// Identifiers on `SettingsScreen`.
class SettingsSemantics {
  const SettingsSemantics._();

  static const addProfileButton = 'helm.settings.add_profile_button';
}

/// Identifiers on `ProfileEditScreen`.
class ProfileEditSemantics {
  const ProfileEditSemantics._();

  static const testConnectionButton =
      'helm.profile_edit.test_connection_button';
  static const multiplexerDropdown = 'helm.profile_edit.multiplexer_dropdown';
}
