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

  /// The AppBar action that opens Settings. This is the only persistent
  /// route to `/settings`, so the E2E suite guards it.
  static const settingsButton = 'helm.home.settings_button';

  /// The AppBar `+` action, only present while there are no tabs.
  static const appBarNewSessionButton = 'helm.home.app_bar_new_session_button';

  /// The large call to action in the empty state.
  static const newSessionButton = 'helm.home.new_session_button';
}

/// Identifiers on `ShortcutsDrawer`.
class ShortcutsSemantics {
  const ShortcutsSemantics._();

  /// The drawer root. Assertions must use this rather than the section
  /// header text: the hamburger's tooltip is "Projects", which Flutter
  /// publishes as a content-description, and Maestro matches text
  /// case-insensitively against the full string. A text assertion for
  /// "PROJECTS" therefore also matches the button on Home and can never
  /// report the drawer as closed.
  static const drawer = 'helm.shortcuts.drawer';

  /// The AGENTS section body. Wraps the agent list AND every one of its
  /// "nothing to show" states, so an E2E flow can assert on the honest
  /// explanation (unsupported / unreachable / genuinely none) rather than
  /// on the absence of rows, which all three would otherwise look like.
  static const agentsSection = 'helm.shortcuts.agents_section';
}

/// Identifiers on `HelmTerminalView`.
class TerminalSemantics {
  const TerminalSemantics._();

  /// The overlay shown whenever the session is not connected. Its
  /// presence is the assertion target for connection-failure flows.
  static const connectionStatusOverlay =
      'helm.terminal.connection_status_overlay';
  static const reconnectButton = 'helm.terminal.reconnect_button';

  /// The host-findings card inside that overlay. Present only when the
  /// probe or the host diagnostics actually found something, so its
  /// absence on a healthy host is itself the correct assertion.
  static const hostAdvisory = 'helm.terminal.host_advisory';

  /// The one-time host key re-authorization prompt, shown in place of the
  /// reconnect block when a host was pinned before Helm changed how it
  /// computes fingerprints.
  ///
  /// Its absence is the assertion an upgrade flow wants on a host that was
  /// never pinned by an older build. Its presence must never be asserted
  /// interchangeably with [connectionStatusOverlay]'s reconnect
  /// affordance: they are mutually exclusive, because reconnecting without
  /// answering this would fail on the very pin it exists to replace.
  static const hostKeyMigration = 'helm.terminal.host_key_migration';

  /// The prompt asking the user to authorize a key algorithm this host has
  /// never presented, shown in place of the reconnect block.
  ///
  /// Distinct from [hostKeyMigration] rather than reusing it, because the
  /// two gates are told apart by exactly one thing — what they say — and a
  /// shared identifier would let a test assert "the user was asked" while
  /// the wrong explanation was on screen.
  static const hostKeyTypeAuthorization =
      'helm.terminal.host_key_type_authorization';
}

/// Identifiers on `FileBrowserSheet`.
class FilesSemantics {
  const FilesSemantics._();

  /// The AppBar action on Home that opens the browser. Present only while
  /// a connected tab exists, so its absence on a dead session is itself
  /// the correct assertion.
  static const browseButton = 'helm.files.browse_button';

  /// The sheet root.
  static const sheet = 'helm.files.sheet';

  /// The bar naming the directory currently shown.
  static const pathBar = 'helm.files.path_bar';

  /// The "go to the containing directory" action.
  static const upButton = 'helm.files.up_button';

  /// The entry list AND every one of its "nothing to show" states.
  ///
  /// One identifier over all of them on purpose, mirroring
  /// [ShortcutsSemantics.agentsSection]: a flow asserts on the honest
  /// explanation inside it — empty, refused, or gone — rather than on the
  /// absence of rows, which all three would otherwise look like.
  static const listing = 'helm.files.listing';

  /// The panel shown when a listing was REFUSED.
  ///
  /// Deliberately distinct from [emptyDirectory]. The two must never be
  /// asserted interchangeably: one says the directory has nothing in it,
  /// the other says nothing is known about it, and a shared identifier
  /// would let a test pass while the browser was telling the user the
  /// opposite of the truth. This is the same rule
  /// [TerminalSemantics.hostKeyTypeAuthorization] follows.
  static const listingError = 'helm.files.listing_error';

  /// The panel shown when a directory was read and held nothing.
  static const emptyDirectory = 'helm.files.empty_directory';

  /// The strip along the bottom of the sheet that reports a transfer.
  ///
  /// One identifier over every phase — running, cancelled, failed, and
  /// "nothing can open this" — for the same reason [listing] covers all of
  /// its states: a flow asserts on what the strip SAYS, not on its
  /// presence, which is the same in all four.
  static const downloadStatus = 'helm.files.download_status';

  /// The action that stops a running transfer.
  static const downloadCancelButton = 'helm.files.download_cancel_button';

  /// The panel shown when a file downloaded but nothing installed can open
  /// it.
  ///
  /// Deliberately distinct from a failure, and the pair must never be
  /// asserted interchangeably — the same rule [listingError] follows. The
  /// transfer SUCCEEDED here; only the hand-off found no taker, and a
  /// shared identifier would let a test pass while the sheet told the user
  /// their download had failed.
  static const downloadNoViewer = 'helm.files.download_no_viewer';

  /// The line reporting where a finished download was filed.
  ///
  /// Covers every publish outcome worth saying — saved, not yet
  /// configured, and each way it can fail — for the same reason [listing]
  /// covers all of its states: a flow asserts on what it SAYS.
  ///
  /// Deliberately NOT folded into [downloadStatus], even though both live
  /// in the same strip. They report independent facts about one transfer,
  /// and can be on screen together: a download can open successfully AND
  /// have failed to reach the user's folder. One identifier over both
  /// would make that pair impossible to assert.
  static const downloadPublish = 'helm.files.download_publish';

  /// The control that chooses, changes or clears the download folder.
  ///
  /// Reachable with NO transfer in flight — a setting the user can only
  /// find mid-download is a setting they cannot find. Absent on platforms
  /// with no folder to choose, where its absence is the correct assertion.
  static const downloadFolderButton = 'helm.files.download_folder_button';
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
