// Widget tests for HostAdvisoryCard.
//
// The card is deliberately thin — it decides nothing, it renders what
// host_advisory.dart already decided. These tests therefore cover only
// presentation contract: show/hide, dismissal, and that remediation copy
// reaches the screen intact rather than being summarised away.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/host/host_advisory.dart';
import 'package:helm/features/terminal/presentation/widgets/host_advisory_card.dart';

const _warning = HostAdvisory(
  id: HostAdvisoryId.multiplexerSubstituted,
  severity: HostAdvisorySeverity.warning,
  title: 'zellij is not installed',
  detail: 'Attached with tmux instead. Available here: tmux, herdr.',
  remediationCopy: 'Install zellij on the host.',
);

const _info = HostAdvisory(
  id: HostAdvisoryId.multiplexerOffPath,
  severity: HostAdvisorySeverity.info,
  title: 'herdr is not on the login PATH',
  detail: 'herdr is installed at /home/deployer/.local/bin/herdr.',
);

Widget _host(List<HostAdvisory> advisories) => MaterialApp(
  home: Scaffold(body: HostAdvisoryCard(advisories: advisories)),
);

void main() {
  testWidgets('renders nothing when there is nothing to report', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const []));

    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('not installed'), findsNothing);
  });

  testWidgets('shows the title and detail of each advisory', (tester) async {
    await tester.pumpWidget(_host(const [_warning, _info]));

    expect(find.text('zellij is not installed'), findsOneWidget);
    expect(
      find.textContaining('Available here: tmux, herdr.'),
      findsOneWidget,
    );
    expect(find.text('herdr is not on the login PATH'), findsOneWidget);
  });

  testWidgets('shows remediation copy verbatim when there is any', (
    tester,
  ) async {
    // Display-only, per HostDiagnostics' governing rule: this text is for
    // the user to act on, never for the app to execute.
    await tester.pumpWidget(_host(const [_warning]));

    expect(find.textContaining('Install zellij on the host.'), findsOneWidget);
  });

  testWidgets('omits the remediation line when there is none', (tester) async {
    await tester.pumpWidget(_host(const [_info]));

    expect(find.textContaining('Install'), findsNothing);
  });

  testWidgets('can be dismissed', (tester) async {
    await tester.pumpWidget(_host(const [_warning]));
    expect(find.text('zellij is not installed'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();

    expect(find.text('zellij is not installed'), findsNothing);
  });

  testWidgets('distinguishes a warning from information', (tester) async {
    await tester.pumpWidget(_host(const [_warning, _info]));

    // Two different icons, so severity is legible without reading the copy.
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });
}
