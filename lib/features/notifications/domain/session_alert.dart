import 'dart:convert';

/// The route prefix that addresses one multiplexer session.
///
/// Lives here rather than in the router because both sides need it and
/// neither owns the other: [SessionAlert.routeLocation] builds a location
/// from it, and `app_router.dart` registers the path that matches.
const String kSessionRoutePrefix = '/session';

/// What the Mac told this device, reduced to the part helm can act on.
///
/// ## The wire contract
///
/// `~/helm-notifier/notifier.py` sends an FCM message whose `data` map is
/// exactly these four keys, all string-valued (FCM's `data` is
/// `map<string,string>` on the wire — `fcm.py` stringifies every value
/// before sending, so nothing else is representable):
///
/// ```
/// session  REQUIRED  the herdr/tmux session name, e.g. "helm-a1b2c3d4"
/// pane_id  optional  the pane the agent occupies,  e.g. "%7"
/// agent    optional  the agent's name,             e.g. "claude"
/// state    optional  "blocked" | "idle"
/// place    optional  the tab, or the cwd basename, e.g. "Go Nexa"
/// area     optional  the workspace,                e.g. "Helm"
/// doing    optional  the agent's terminal title,   e.g. "OC | sync files"
/// ```
///
/// ### Why blank and absent are the same thing here
///
/// FCM's `data` is `map<string,string>` on the wire. The sender has no way
/// to express "I could not work out the workspace" other than by sending
/// an empty string, so an empty string HAS to be read as absent — the
/// alternative is a notification header that renders as a bare separator
/// with nothing after it. [fromData] therefore trims every value and
/// treats what is left of a blank one as null, uniformly, including for
/// the three keys that predate this rule.
///
/// ### Why `session` is the only required key, and the only routing key
///
/// helm addresses a session BY NAME and by nothing else. `TerminalSession`
/// is constructed with a `tmuxSessionName`, `TabsNotifier.addTab` takes it
/// as `tmuxSessionName`, and `resolveSessionName` decides from that name
/// alone whether to attach a new tab or focus the tab already holding it.
/// The name in herdr's `session list` and the name helm attaches to are
/// the same string, so it needs no translation.
///
/// `pane_id`, `agent` and `state` are deliberately NOT part of the routing
/// decision. helm has no route addressing a pane, and inventing one would
/// mean the notifier could send a payload this app silently could not
/// honour. They are carried because they are what the notification is
/// ABOUT — worth showing, worth logging — and dropping them would mean the
/// sender has to be changed the first time either becomes displayable.
///
/// ### Why the profile is absent from the contract
///
/// The notifier runs on the Mac and knows nothing about helm's connection
/// profiles — they are a phone-side concept with phone-minted UUIDs.
/// Requiring one would make the payload depend on state the sender cannot
/// see. Resolution is helm's job: a session already open in a tab is
/// focused wherever it is, and otherwise the default profile is dialled.
/// See `PendingSessionAlert` for that rule.
class SessionAlert {
  const SessionAlert({
    required this.sessionName,
    this.paneId,
    this.agent,
    this.state,
    this.place,
    this.area,
    this.doing,
  });

  /// The herdr/tmux session name. The routing key, and never empty.
  final String sessionName;

  /// The pane the agent occupies, when the sender knew it.
  final String? paneId;

  /// The agent's name, when the sender knew it.
  final String? agent;

  /// `blocked` or `idle` — kept as a [String] on purpose.
  ///
  /// Parsing it into an enum here would mean a state herdr adds later
  /// arrives as a value this app rejects. The notification is worth
  /// showing whatever the state is called.
  final String? state;

  /// Where the agent is working — the tab's label, or the basename of its
  /// working directory when the tab was never named.
  ///
  /// The sender already spends the notification TITLE on this, so helm
  /// does not draw it a second time. It is carried because the title is a
  /// pre-rendered string this app cannot take apart, and anything that
  /// wants to lay the same facts out differently needs them separately.
  final String? place;

  /// The workspace the [place] belongs to.
  ///
  /// Deliberately NOT in the title. The sender measured
  /// `Helm · Go Nexa · opencode is done` at 33 characters and watched it
  /// truncate on a physical S22 Ultra, against a budget of roughly 30, so
  /// it dropped this one. helm draws it in the notification's header line
  /// instead — see `subText` in [LocalNotificationPresenter.show] — which
  /// is space the title was never competing for.
  ///
  /// The pair reads `place · area`, which is the same order and the same
  /// separator `agentContextLabel` already uses in the drawer. One
  /// vocabulary, two surfaces.
  final String? area;

  /// What the agent is doing, as its own terminal title.
  ///
  /// The sender puts this in the notification BODY, so it normally
  /// arrives twice. It is read here only as a fallback for a message that
  /// carried a title and no body.
  final String? doing;

  /// What this alert is ABOUT, for deciding which tray slot it owns.
  ///
  /// Two agents must not share a slot — that was the original bug, where
  /// one constant id made the second agent to speak erase the first. The
  /// pane is the finest thing the sender knows, and the session name is
  /// the coarsest thing it always knows, so the key degrades from one to
  /// the other rather than to a shared constant.
  ///
  /// The session is part of the key even when a pane is known, because a
  /// pane id is only unique WITHIN one multiplexer server. Two Macs, or
  /// two servers on one Mac, both call their first pane `%0`.
  ///
  /// The separator is NUL rather than a readable character on purpose:
  /// tmux permits `/`, `·` and every printable byte in a session name, so
  /// any of those would let one session's name forge another session's
  /// key. NUL cannot appear in either half.
  String get notificationGroupingKey =>
      paneId == null ? sessionName : '$sessionName\u0000$paneId';

  /// Reads an FCM `data` map, or null when it does not identify a session.
  ///
  /// Never throws, and that is a requirement rather than politeness: one
  /// caller is a background isolate where an exception has no UI to reach
  /// and no user to inform. A payload this app cannot understand degrades
  /// to "no deep link", never to a crash.
  static SessionAlert? fromData(Map<String, dynamic> data) {
    final session = _presentString(data['session']);
    if (session == null) return null;

    return SessionAlert(
      sessionName: session,
      paneId: _presentString(data['pane_id']),
      agent: _presentString(data['agent']),
      state: _presentString(data['state']),
      place: _presentString(data['place']),
      area: _presentString(data['area']),
      doing: _presentString(data['doing']),
    );
  }

  /// Reads back a [toPayload] string, or null when it is not one.
  ///
  /// The inverse exists because the two delivery paths carry different
  /// shapes: FCM hands over a `Map`, while `flutter_local_notifications`
  /// carries a single `String? payload`. JSON is the bridge, so a tap on a
  /// foreground notification resolves to the same [SessionAlert] the
  /// message arrived as.
  static SessionAlert? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      return fromData(Map<String, dynamic>.from(decoded));
    } on FormatException {
      return null;
    }
  }

  /// This alert as the string `flutter_local_notifications` can carry.
  ///
  /// Carries the display context as well as the routing key, even though
  /// only the routing key is read on a tap. A round-trip that silently
  /// dropped fields would be a trap for whoever next reaches for one, and
  /// the cost is a few dozen bytes in a string nobody but this app reads.
  ///
  /// Absent values are OMITTED rather than written as null, so the
  /// payload never carries the four characters that would show up in a
  /// log looking like a bug.
  String toPayload() => jsonEncode({
    'session': sessionName,
    if (paneId != null) 'pane_id': paneId,
    if (agent != null) 'agent': agent,
    if (state != null) 'state': state,
    if (place != null) 'place': place,
    if (area != null) 'area': area,
    if (doing != null) 'doing': doing,
  });

  /// The go_router location that opens this session.
  ///
  /// The name is percent-encoded because it is a remote string this app
  /// does not control. tmux permits `/` in a session name, and an
  /// unencoded one would add a path segment — silently addressing a route
  /// the notification never asked for.
  String get routeLocation =>
      '$kSessionRoutePrefix/${Uri.encodeComponent(sessionName)}';

  /// [value] as a trimmed string, or null when it is not usably present.
  ///
  /// Collapses THREE ways of not knowing into one: the key was absent,
  /// the value was not a string (a background isolate can be handed a
  /// decoded map from anywhere), or the sender sent whitespace because
  /// FCM's string-only data map gave it no way to send nothing.
  static String? _presentString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
