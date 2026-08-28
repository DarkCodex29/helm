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
/// ```
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

  /// Reads an FCM `data` map, or null when it does not identify a session.
  ///
  /// Never throws, and that is a requirement rather than politeness: one
  /// caller is a background isolate where an exception has no UI to reach
  /// and no user to inform. A payload this app cannot understand degrades
  /// to "no deep link", never to a crash.
  static SessionAlert? fromData(Map<String, dynamic> data) {
    final session = _stringOrNull(data['session'])?.trim();
    if (session == null || session.isEmpty) return null;

    return SessionAlert(
      sessionName: session,
      paneId: _stringOrNull(data['pane_id']),
      agent: _stringOrNull(data['agent']),
      state: _stringOrNull(data['state']),
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
  String toPayload() => jsonEncode({
    'session': sessionName,
    if (paneId != null) 'pane_id': paneId,
    if (agent != null) 'agent': agent,
    if (state != null) 'state': state,
  });

  /// The go_router location that opens this session.
  ///
  /// The name is percent-encoded because it is a remote string this app
  /// does not control. tmux permits `/` in a session name, and an
  /// unencoded one would add a path segment — silently addressing a route
  /// the notification never asked for.
  String get routeLocation =>
      '$kSessionRoutePrefix/${Uri.encodeComponent(sessionName)}';

  static String? _stringOrNull(Object? value) =>
      value is String ? value : null;
}
