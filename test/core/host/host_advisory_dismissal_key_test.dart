// A dismissal has to be keyed on something that outlives the widget.
//
// Written after a real-device session showed dismissed advisories coming
// back: dismissal lived in `_HostAdvisoryCardState._dismissed`, and every
// reconnect unmounts that card — `TerminalSession.connect()` clears
// `advisoriesNotifier` and `_resolveMultiplexer` repopulates it. The user
// dismissed the same finding on every reconnect, forever.
//
// Moving the state out is only half the fix. The other half is WHAT it is
// keyed on. [HostAdvisoryId] alone is too coarse: the id says which CHECK
// produced the finding, not what the finding said. Reconnect after
// pointing the profile at a different multiplexer and
// `multiplexerSubstituted` fires again about something else entirely —
// that is a new thing to tell the user, and it must not arrive
// pre-dismissed because an older, differently-worded finding shared its
// id.
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_advisory.dart';

const _zellijSubstituted = HostAdvisory(
  id: HostAdvisoryId.multiplexerSubstituted,
  severity: HostAdvisorySeverity.warning,
  title: 'zellij is not installed',
  detail: 'Attached with herdr instead. Available here: herdr, tmux.',
  remediationCopy: 'Install zellij on the host.',
);

void main() {
  group('HostAdvisory.dismissalKey', () {
    test('is stable for the same finding, so a dismissal keeps holding', () {
      // Advisories are rebuilt from the probe on every connect — never
      // reused as objects. A key derived from identity rather than from
      // instance is what lets a dismissal survive that.
      const rebuilt = HostAdvisory(
        id: HostAdvisoryId.multiplexerSubstituted,
        severity: HostAdvisorySeverity.warning,
        title: 'zellij is not installed',
        detail: 'Attached with herdr instead. Available here: herdr, tmux.',
        remediationCopy: 'Install zellij on the host.',
      );

      expect(rebuilt.dismissalKey, _zellijSubstituted.dismissalKey);
    });

    test(
      'differs when the SAME check reports something different, so a '
      'genuinely new finding is never born already dismissed',
      () {
        // Same id, different substance: the profile was changed from
        // zellij to tmux and the host has neither.
        const tmuxSubstituted = HostAdvisory(
          id: HostAdvisoryId.multiplexerSubstituted,
          severity: HostAdvisorySeverity.warning,
          title: 'tmux is not installed',
          detail: 'Attached with herdr instead. Available here: herdr.',
          remediationCopy: 'Install tmux on the host.',
        );

        expect(
          tmuxSubstituted.dismissalKey,
          isNot(_zellijSubstituted.dismissalKey),
          reason:
              'keying on HostAdvisoryId alone would hide this new finding '
              'behind a dismissal the user made about a different one',
        );
      },
    );

    test('differs when only the title changed', () {
      // Today's two advisory sources happen to move title and detail
      // together, so a key built from detail alone would pass every other
      // case here. It is pinned separately because the title is the line
      // the user actually reads first: a finding that renamed itself is a
      // finding they have not seen, whatever the body says.
      const otherTitle = HostAdvisory(
        id: HostAdvisoryId.multiplexerSubstituted,
        severity: HostAdvisorySeverity.warning,
        title: 'tmux is not installed',
        detail: 'Attached with herdr instead. Available here: herdr, tmux.',
        remediationCopy: 'Install zellij on the host.',
      );

      expect(otherTitle.dismissalKey, isNot(_zellijSubstituted.dismissalKey));
    });

    test('differs when only the detail changed', () {
      const otherDetail = HostAdvisory(
        id: HostAdvisoryId.multiplexerSubstituted,
        severity: HostAdvisorySeverity.warning,
        title: 'zellij is not installed',
        detail: 'Attached with tmux instead. Available here: tmux.',
        remediationCopy: 'Install zellij on the host.',
      );

      expect(otherDetail.dismissalKey, isNot(_zellijSubstituted.dismissalKey));
    });

    test('differs when only the severity changed', () {
      // The same words at a different volume are a different statement:
      // a check that degraded from info to warning is news.
      const escalated = HostAdvisory(
        id: HostAdvisoryId.multiplexerSubstituted,
        severity: HostAdvisorySeverity.info,
        title: 'zellij is not installed',
        detail: 'Attached with herdr instead. Available here: herdr, tmux.',
        remediationCopy: 'Install zellij on the host.',
      );

      expect(escalated.dismissalKey, isNot(_zellijSubstituted.dismissalKey));
    });

    test('differs when only the remediation changed', () {
      const otherRemediation = HostAdvisory(
        id: HostAdvisoryId.multiplexerSubstituted,
        severity: HostAdvisorySeverity.warning,
        title: 'zellij is not installed',
        detail: 'Attached with herdr instead. Available here: herdr, tmux.',
        remediationCopy: 'Ask your administrator to install zellij.',
      );

      expect(
        otherRemediation.dismissalKey,
        isNot(_zellijSubstituted.dismissalKey),
      );
    });

    test('separates its fields so their contents cannot forge a match', () {
      // Naive concatenation makes ('ab', 'c') and ('a', 'bc') the same
      // key. Two findings would then share a dismissal by coincidence of
      // where a word break fell.
      const a = HostAdvisory(
        id: HostAdvisoryId.multiplexerOffPath,
        severity: HostAdvisorySeverity.info,
        title: 'ab',
        detail: 'c',
      );
      const b = HostAdvisory(
        id: HostAdvisoryId.multiplexerOffPath,
        severity: HostAdvisorySeverity.info,
        title: 'a',
        detail: 'bc',
      );

      expect(a.dismissalKey, isNot(b.dismissalKey));
    });

    test('distinguishes a null remediation from an empty one', () {
      const none = HostAdvisory(
        id: HostAdvisoryId.multiplexerOffPath,
        severity: HostAdvisorySeverity.info,
        title: 'herdr is not on the login PATH',
        detail: 'Installed at /home/deployer/.local/bin/herdr.',
      );
      const empty = HostAdvisory(
        id: HostAdvisoryId.multiplexerOffPath,
        severity: HostAdvisorySeverity.info,
        title: 'herdr is not on the login PATH',
        detail: 'Installed at /home/deployer/.local/bin/herdr.',
        remediationCopy: '',
      );

      expect(none.dismissalKey, isNot(empty.dismissalKey));
    });
  });
}
