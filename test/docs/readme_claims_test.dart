import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/terminal/presentation/widgets/terminal_keyboard.dart';
import 'package:xterm/xterm.dart';

// Existing notification source tests use relative File paths. Walk from the
// runner's script instead: Flutter places its compiled test inside the package,
// so this works without assuming Directory.current is the package root.
Future<Directory> repositoryRoot() async {
  var directory = File.fromUri(Platform.script).parent;
  while (true) {
    final manifest = File.fromUri(directory.uri.resolve('pubspec.yaml'));
    if (manifest.existsSync() &&
        RegExp(
          r'^name: helm$',
          multiLine: true,
        ).hasMatch(manifest.readAsStringSync())) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Cannot find Helm above test script ${Platform.script}');
    }
    directory = parent;
  }
}

String capture(String text, String pattern, [int group = 1]) {
  final match = RegExp(pattern, multiLine: true).firstMatch(text);
  expect(
    match,
    isNotNull,
    reason: 'Missing checkable claim/definition: $pattern',
  );
  return match!.group(group)!;
}

// Strip comments before inspecting declarations; explanatory comments cannot
// satisfy a source assertion. These inspected declarations contain no URLs.
String codeOnly(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');

void main() {
  late Directory root;
  late String readme;
  late String keyboard;
  late String upload;
  late String picker;
  String read(String path) =>
      File.fromUri(root.uri.resolve(path)).readAsStringSync();

  setUpAll(() async {
    root = await repositoryRoot();
    readme = read('README.md').replaceAll(RegExp(r'\s+'), ' ');
    keyboard = codeOnly(
      read('lib/features/terminal/presentation/widgets/terminal_keyboard.dart'),
    );
    upload = codeOnly(read('lib/features/files/data/sftp_upload_service.dart'));
    picker = codeOnly(read('lib/features/files/data/saf_upload_source.dart'));
  });

  test(
    'repository lookup is independent of the current working directory',
    () async {
      final original = Directory.current;
      try {
        Directory.current = root.parent;
        expect((await repositoryRoot()).path, root.path);
        expect(read('README.md'), contains('# Helm'));
      } finally {
        Directory.current = original;
      }
    },
  );

  test('README keyboard bounds match the panel definitions', () {
    final widths = RegExp(
      r'entre (\d+) y (\d+) píxeles lógicos de ancho',
    ).firstMatch(readme);
    final heights = RegExp(r'entre (\d+) y (\d+) de alto').firstMatch(readme);
    expect(widths, isNotNull);
    expect(heights, isNotNull);
    // Import the arithmetic width constant rather than reimplementing its sum.
    expect(double.parse(widths!.group(1)!), keyboardMinimumWidth);
    expect(double.parse(widths.group(2)!), keyboardMaximumWidth);
    for (final entry in {'minHeight': 1, 'maxHeight': 2}.entries) {
      final bound = capture(
        keyboard,
        'final ${entry.key} = math\\.min\\(([0-9.]+),',
      );
      expect(double.parse(heights!.group(entry.value)!), double.parse(bound));
    }
  });

  test('README free-name budget matches the bounded search', () {
    final budget = int.parse(
      capture(upload, r'const _nameCandidates = (\d+);'),
    );
    expect(int.parse(capture(readme, r'límite de (\d+) candidatos')), budget);
    expect(upload, contains('i < _nameCandidates'));
    final alternatives = int.parse(
      capture(readme, r'original y (\d+) alternativas'),
    );
    expect(alternatives, budget - 1);
  });

  testWidgets('README advertised keyboard controls are rendered keys', (
    tester,
  ) async {
    final advertised = capture(readme, r'Teclado flotante con ([^;]+);');
    final labels = advertised
        .split(RegExp(r',\s*|\s+y\s+|/'))
        .map((label) => label.trim())
        .expand((label) => label == 'flechas' ? ['←', '↑', '↓', '→'] : [label]);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              child: TerminalKeyboard(terminal: Terminal()),
            ),
          ),
        ),
      ),
    );
    final rendered = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .toSet();
    for (final label in labels) {
      expect(
        rendered,
        contains(label),
        reason: 'README advertises an absent key: $label',
      );
    }
    // A future removal must be detectable even if comments retain the label.
    // Use every advertised label as a removal fixture, not a paging blocklist.
    for (final label in labels) {
      final afterRemoval = {...rendered}..remove(label);
      expect(
        labels.where((claim) => !afterRemoval.contains(claim)),
        contains(label),
      );
    }
  });

  test('README Android-only upload and gallery share the production gate', () {
    final platform = capture(
      picker,
      r'supportsPicking = supportsPicking \?\? Platform\.is(\w+);',
    );
    final documented = capture(
      readme,
      r'La subida y el selector de galería son solo para (\w+)',
    );
    expect(documented.toLowerCase(), platform.toLowerCase());
    for (final method in ['pick', 'pickMedia']) {
      expect(
        picker,
        matches(
          RegExp(
            '$method\\(\\) async \\{\\s*if \\(!supportsPicking\\) return null;',
          ),
        ),
      );
    }
    final sheet = codeOnly(
      read('lib/features/files/presentation/file_browser_sheet.dart'),
    );
    expect(sheet, contains('showUpload: picker.supportsPicking'));
    final provider = codeOnly(
      read(
        'lib/features/files/presentation/providers/file_upload_provider.dart',
      ),
    );
    expect(
      provider,
      contains('UploadSourcePicker(gateway: SafDocumentTreeGateway())'),
    );
  });

  test(
    'README does not claim hardware generation for a Dart-generated SSH key',
    () {
      final service = codeOnly(
        read('lib/features/connection/data/ssh_key_service.dart'),
      );
      expect(
        service,
        contains('final signingKey = pinenacl.SigningKey.generate();'),
      );
      expect(service, contains('value: privatePem,'));
      final generation = capture(
        read('README.md'),
        r'La app genera una SSH key Ed25519 ([^\n]+)',
      );
      expect(
        generation,
        isNot(contains('Secure Enclave')),
        reason:
            'SSHKeyService generates the key in Dart, not in Secure Enclave',
      );
      expect(
        generation,
        isNot(contains('en el Keystore')),
        reason: 'Secure storage persists the PEM; it does not generate the key',
      );
    },
  );
}
