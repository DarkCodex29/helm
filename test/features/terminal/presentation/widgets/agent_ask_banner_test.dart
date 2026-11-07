@Timeout(Duration(seconds: 30))
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/core/testing/semantic_ids.dart';
import 'package:helm/features/agentd/data/agentd_client.dart';
import 'package:helm/features/agentd/data/agentd_providers.dart';
import 'package:helm/features/agentd/domain/agentd_endpoint.dart';
import 'package:helm/features/terminal/presentation/widgets/agent_ask_banner.dart';
import 'package:helm_protocol/helm_protocol.dart' as proto;

import '../../../agentd/support/fakes.dart';

const _token = 'FAKEfakeFAKEfakeFAKEfakeFAKEfakeFAKEfakeFAK';

proto.AskMessage _confirm(String id) => proto.AskMessage(
  requestId: id,
  method: 'confirm',
  title: 'Proceed?',
  message: 'The agent wants to continue.',
);

proto.AskMessage _select(String id) => proto.AskMessage(
  requestId: id,
  method: 'select',
  title: 'Allow?',
  options: const ['Allow', 'Block'],
);

void main() {
  late FakeConnector connector;
  late List<AgentdClient> built;

  setUp(() {
    connector = FakeConnector();
    built = [];
  });

  Future<void> pumpBanner(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentdClientProvider.overrideWith((ref, id) async {
            final client = AgentdClient(
              endpoint: const AgentdEndpoint(host: '127.0.0.1', port: 1),
              token: _token,
              connect: connector.call,
            );
            built.add(client);
            ref.onDispose(client.close);
            return client;
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: AgentAskBanner(profileId: 'p1')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    connector.last.serveReady();
    await tester.pump();
  }

  Future<void> serve(WidgetTester tester, proto.ServerMessage m) async {
    connector.last.serve(m);
    await tester.pump();
    await tester.pump();
  }

  List<proto.ClientUiResponse> answers() =>
      connector.last.clientFrames.whereType<proto.ClientUiResponse>().toList();

  Finder id(String s) => find.bySemanticsIdentifier(s);

  tearDown(() async {
    for (final c in built) {
      await c.close();
    }
  });

  testWidgets('hidden when no ask is open', (tester) async {
    await pumpBanner(tester);
    expect(id(AgentAskSemantics.banner), findsNothing);
  });

  testWidgets('hidden when the ask is open but the link is down', (
    tester,
  ) async {
    await pumpBanner(tester);
    await serve(tester, _confirm('a1'));
    expect(id(AgentAskSemantics.banner), findsOneWidget);
    connector.last.serverClose(1006);
    await tester.pump();
    await tester.pump();
    expect(id(AgentAskSemantics.banner), findsNothing);
  });

  testWidgets('confirm: Confirm and Decline send the right frame', (
    tester,
  ) async {
    await pumpBanner(tester);
    await serve(tester, _confirm('a1'));
    expect(find.text('Agent needs you'), findsOneWidget);
    expect(find.text('Proceed?'), findsOneWidget);
    expect(find.text('The agent wants to continue.'), findsOneWidget);

    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(answers().single.requestId, 'a1');
    expect(answers().single.confirmed, true);
    await serve(tester, const proto.AskResolvedMessage('a1'));
    expect(id(AgentAskSemantics.banner), findsNothing);

    await serve(tester, _confirm('a2'));
    await tester.tap(find.text('Decline'));
    await tester.pump();
    expect(answers().last.requestId, 'a2');
    expect(answers().last.confirmed, false);
  });

  testWidgets('select: one button per option, value is the option', (
    tester,
  ) async {
    await pumpBanner(tester);
    await serve(tester, _select('s1'));
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
    expect(find.text('Confirm'), findsNothing);
    await tester.tap(find.text('Block'));
    await tester.pump();
    expect(answers().single.requestId, 's1');
    expect(answers().single.value, 'Block');
    expect(answers().single.confirmed, isNull);
  });

  testWidgets('Cancel sends cancelled', (tester) async {
    await pumpBanner(tester);
    await serve(tester, _select('s1'));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(answers().single.cancelled, true);
    expect(answers().single.value, isNull);
  });

  testWidgets('a double tap sends one frame and disables the buttons', (
    tester,
  ) async {
    await pumpBanner(tester);
    await serve(tester, _confirm('a1'));
    await tester.tap(find.text('Confirm'));
    await tester.tap(find.text('Confirm'), warnIfMissed: false);
    await tester.tap(find.text('Decline'), warnIfMissed: false);
    await tester.pump();
    expect(answers(), hasLength(1));
    final confirm = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Confirm'),
    );
    expect(confirm.onPressed, isNull);
    final decline = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Decline'),
    );
    expect(decline.onPressed, isNull);
  });

  testWidgets('input and editor: Mac hint, Cancel, no text field', (
    tester,
  ) async {
    for (final method in ['input', 'editor']) {
      await pumpBanner(tester);
      await serve(
        tester,
        proto.AskMessage(requestId: method, method: method, title: 'Name?'),
      );
      expect(find.text('Answer this on the Mac'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Confirm'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      for (final c in built) {
        await c.close();
      }
      built.clear();
      connector.channels.clear();
    }
  });

  testWidgets('+N more counts the other open asks', (tester) async {
    await pumpBanner(tester);
    await serve(tester, _confirm('a1'));
    expect(id(AgentAskSemantics.more), findsNothing);
    await serve(tester, _confirm('a2'));
    await serve(tester, _select('a3'));
    expect(find.text('+2 more'), findsOneWidget);
    expect(find.text('Proceed?'), findsOneWidget); // the first, only
    await serve(tester, const proto.AskResolvedMessage('a1'));
    expect(find.text('+1 more'), findsOneWidget);
    expect(find.text('Proceed?'), findsOneWidget); // a2 now
  });

  testWidgets('another device answered first: no error text, row goes', (
    tester,
  ) async {
    await pumpBanner(tester);
    await serve(tester, _confirm('a1'));
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    // The daemon rejects our late answer, then tells everyone it is resolved.
    await serve(
      tester,
      const proto.ErrorMessage(
        code: 'ask_resolved',
        message: 'ask a1 already resolved',
        requestId: 'a1',
      ),
    );
    expect(find.text('Could not send, try again'), findsNothing);
    await serve(tester, const proto.AskResolvedMessage('a1'));
    expect(id(AgentAskSemantics.banner), findsNothing);
    expect(find.text('Could not send, try again'), findsNothing);
  });

  testWidgets('another failure shows retry text and re-enables buttons', (
    tester,
  ) async {
    await pumpBanner(tester);
    await serve(tester, _confirm('a1'));
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    await serve(
      tester,
      const proto.ErrorMessage(
        code: 'internal',
        message: 'ask a1 failed',
        requestId: 'a1',
      ),
    );
    expect(find.text('Could not send, try again'), findsOneWidget);
    final confirm = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Confirm'),
    );
    expect(confirm.onPressed, isNotNull);
  });

  testWidgets('semantics: header, labelled actions, 48dp targets', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpBanner(tester);
    await serve(tester, _select('s1'));
    expect(id(AgentAskSemantics.header), findsOneWidget);
    expect(id(AgentAskSemantics.option(0)), findsOneWidget);
    expect(id(AgentAskSemantics.option(1)), findsOneWidget);
    expect(id(AgentAskSemantics.cancelButton), findsOneWidget);
    expect(find.bySemanticsLabel('Allow'), findsOneWidget);
    expect(find.bySemanticsLabel('Agent needs you'), findsOneWidget);
    for (final label in ['Allow', 'Block', 'Cancel']) {
      final size = tester.getSize(
        find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      );
      expect(size.height, greaterThanOrEqualTo(48), reason: label);
      expect(size.width, greaterThanOrEqualTo(48), reason: label);
    }
    handle.dispose();
  });
}
