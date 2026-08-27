// Which multiplexer session a new tab attaches to.
//
// Two defects, verified against the running app, drive this file.
//
// 1. `TabsNotifier.addTab` computed `'helm-${state.tabs.length}'`. That
//    counter is derived from the CURRENT tab count, which is not
//    monotonic:
//
//        [helm-0, helm-1] -> close helm-0 -> new tab -> count 1 -> helm-1
//
//    Reproduced exactly: the tab list went to [helm-1, helm-1]. Two tabs
//    then attach to ONE herdr session, render the same screen, and — since
//    62565f3 taught each tab to resize the remote PTY to its own viewport
//    — actively fight over that session's size.
//
// 2. `profile.sessionRef` was never read. The profile editor persists a
//    "Session reference (optional)" field, reloads it, and nothing opens
//    it: measured, a profile with sessionRef "my-work" opened "helm-0".
//    Same class of unkept promise as the launch copy fixed in 64a321d.
//
// The rule lives here rather than inside `addTab` for the reason this
// codebase already applies to `host_advisory.dart` and
// `session_reference.dart`: it is a decision, and decisions are worth
// testing without a provider container around them.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/connection/domain/connection_profile.dart';
import 'package:helm/features/terminal/domain/session_name.dart';

const _plain = ConnectionProfile(
  id: 'p1',
  name: 'VPS',
  host: '158.220.106.131',
  username: 'deployer',
);

const _named = ConnectionProfile(
  id: 'p2',
  name: 'VPS Work',
  host: '158.220.106.131',
  username: 'deployer',
  sessionRef: 'my-work',
);

/// A generator that hands out predictable suffixes, so these tests assert
/// on the RULE rather than on a random draw.
String Function() _suffixes(List<String> values) {
  var i = 0;
  return () => values[i++];
}

SessionNameResolution _resolve({
  ConnectionProfile profile = _plain,
  String? requested,
  List<OpenTabSession> openTabs = const [],
  List<String> suffixes = const ['aaaa1111'],
}) => resolveSessionName(
  profile: profile,
  requestedSessionName: requested,
  openTabs: openTabs,
  mintSuffix: _suffixes(suffixes),
);

void main() {
  group("the profile's own session reference is honored", () {
    test('a profile with sessionRef opens THAT session', () {
      final result = _resolve(profile: _named);

      expect(result, isA<OpenSession>());
      expect((result as OpenSession).sessionName, 'my-work');
    });

    test('the legacy tmuxSession field still works when sessionRef is not '
        'set', () {
      const legacy = ConnectionProfile(
        id: 'p3',
        name: 'Old',
        host: 'h',
        username: 'u',
        tmuxSession: 'legacy-name',
      );

      final result = _resolve(profile: legacy);

      expect((result as OpenSession).sessionName, 'legacy-name');
    });

    test('sessionRef wins over the legacy field', () {
      const both = ConnectionProfile(
        id: 'p4',
        name: 'Both',
        host: 'h',
        username: 'u',
        tmuxSession: 'legacy-name',
        sessionRef: 'neutral-name',
      );

      expect((_resolve(profile: both) as OpenSession).sessionName,
          'neutral-name');
    });

    test('a blank session reference is not a name', () {
      // The editor stores whatever was typed. Whitespace is the user
      // leaving the field alone, not naming a session called "   ".
      const blank = ConnectionProfile(
        id: 'p5',
        name: 'Blank',
        host: 'h',
        username: 'u',
        sessionRef: '   ',
      );

      expect(
        (_resolve(profile: blank) as OpenSession).sessionName,
        'helm-aaaa1111',
      );
    });

    test('a session reference is trimmed before it is used', () {
      const padded = ConnectionProfile(
        id: 'p6',
        name: 'Padded',
        host: 'h',
        username: 'u',
        sessionRef: '  my-work  ',
      );

      expect(
        (_resolve(profile: padded) as OpenSession).sessionName,
        'my-work',
      );
    });
  });

  group('an explicit request outranks the profile', () {
    test('crash recovery reattaches to the session it snapshotted', () {
      // recoverSession hands in the snapshot's name. That is the whole
      // point of a snapshot and must beat anything the profile says.
      final result = _resolve(profile: _named, requested: 'helm-2');

      expect((result as OpenSession).sessionName, 'helm-2');
    });

    test('a shortcut opens the session it names', () {
      final result = _resolve(profile: _named, requested: 'metalpren');

      expect((result as OpenSession).sessionName, 'metalpren');
    });

    test('a blank explicit request falls through to the profile', () {
      expect(
        (_resolve(profile: _named, requested: '  ') as OpenSession)
            .sessionName,
        'my-work',
      );
    });
  });

  group('a generated name cannot collide with an open tab', () {
    test('the reported sequence no longer produces a duplicate', () {
      // [helm-0, helm-1] -> close helm-0 -> open a third tab. A positional
      // counter answers "helm-1", the name still on screen.
      final result = _resolve(
        openTabs: const [(tabId: 't2', sessionName: 'helm-1')],
        suffixes: ['bbbb2222'],
      );

      expect((result as OpenSession).sessionName, isNot('helm-1'));
      expect(result.sessionName, 'helm-bbbb2222');
    });

    test('it is not derived from how many tabs are open', () {
      // The same tab count must not force the same answer — that property
      // IS the defect.
      final one = _resolve(
        openTabs: const [(tabId: 't1', sessionName: 'helm-x')],
        suffixes: ['cccc3333'],
      );
      final two = _resolve(
        openTabs: const [(tabId: 't9', sessionName: 'helm-y')],
        suffixes: ['dddd4444'],
      );

      expect(
        (one as OpenSession).sessionName,
        isNot((two as OpenSession).sessionName),
      );
    });

    test('a minted name that IS taken is redrawn until it is free', () {
      // Structural, not probabilistic: the guarantee must not rest on a
      // random draw happening not to repeat.
      final result = _resolve(
        openTabs: const [
          (tabId: 't1', sessionName: 'helm-eeee5555'),
          (tabId: 't2', sessionName: 'helm-ffff6666'),
        ],
        suffixes: ['eeee5555', 'ffff6666', 'gggg7777'],
      );

      expect((result as OpenSession).sessionName, 'helm-gggg7777');
    });

    test('generated names keep the helm- prefix', () {
      // The host is shared with sessions helm did not create; the prefix
      // is how a human tells them apart in `herdr session list`.
      expect(
        (_resolve(suffixes: ['hhhh8888']) as OpenSession).sessionName,
        startsWith('helm-'),
      );
    });

    test('a tab with no session name of its own is ignored, not matched', () {
      // A tab still resolving its name has nothing to collide with. It
      // must not swallow the minted candidate by comparing equal to null.
      final result = _resolve(
        openTabs: const [(tabId: 't1', sessionName: null)],
        suffixes: ['iiii9999'],
      );

      expect((result as OpenSession).sessionName, 'helm-iiii9999');
    });
  });

  group('two tabs never share one session', () {
    test(
      'opening a NAMED profile that is already open focuses the tab that '
      'has it, rather than attaching twice',
      () {
        final result = _resolve(
          profile: _named,
          openTabs: const [(tabId: 'tab-7', sessionName: 'my-work')],
        );

        expect(result, isA<FocusOpenTab>());
        expect((result as FocusOpenTab).tabId, 'tab-7');
        expect(result.sessionName, 'my-work');
      },
    );

    test('an explicitly requested session already open is focused too', () {
      // Crash recovery replaying a snapshot twice, or a shortcut opened
      // twice, must not produce a second attach to one session.
      final result = _resolve(
        requested: 'metalpren',
        openTabs: const [(tabId: 'tab-3', sessionName: 'metalpren')],
      );

      expect((result as FocusOpenTab).tabId, 'tab-3');
    });

    test(
      'opening an UNNAMED profile twice gives a second, distinct session',
      () {
        // The counterpart decision. A profile with no session reference
        // has not claimed there is only one of these, so a second tab is
        // a second shell — which is what the user asked for — and it gets
        // a session of its own rather than fighting over one.
        final result = _resolve(
          openTabs: const [(tabId: 't1', sessionName: 'helm-jjjj0000')],
          suffixes: ['kkkk1111'],
        );

        expect(result, isA<OpenSession>());
        expect((result as OpenSession).sessionName, 'helm-kkkk1111');
      },
    );

    test('the same NAMED profile in two different tabs is impossible', () {
      // Resolving twice against the state the first one produced can
      // never hand back a second OpenSession for that name.
      final first = _resolve(profile: _named) as OpenSession;
      final second = _resolve(
        profile: _named,
        openTabs: [(tabId: 'tab-1', sessionName: first.sessionName)],
      );

      expect(second, isA<FocusOpenTab>());
    });

    test('a different profile naming the SAME session is also focused', () {
      // Session identity is the name on the host, not the profile that
      // happens to point at it. Two profiles pointing at one session are
      // still one session.
      const other = ConnectionProfile(
        id: 'p-other',
        name: 'Other',
        host: '158.220.106.131',
        username: 'deployer',
        sessionRef: 'my-work',
      );

      final result = _resolve(
        profile: other,
        openTabs: const [(tabId: 'tab-7', sessionName: 'my-work')],
      );

      expect((result as FocusOpenTab).tabId, 'tab-7');
    });
  });
}
