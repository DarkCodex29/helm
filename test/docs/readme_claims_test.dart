import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm/features/files/data/sftp_session.dart';
import 'package:helm/features/files/data/sftp_upload_service.dart';
import 'package:helm/features/files/domain/upload_outcome.dart';
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

  test('README naming examples match real uploads on collisions', () async {
    final examples = RegExp(r'`([^`]+)` → `([^`]+)`')
        .allMatches(readme)
        .where(
          (match) =>
              match.group(1)!.startsWith('foto') || match.group(1) == '.env',
        );
    expect(examples.length, 4);
    for (final example in examples) {
      final requested = '/uploads/${example.group(1)}';
      final session = _NamingSession(occupied: {requested});
      final outcome = await SftpUploadService.withOpener(
        () async => session,
      ).upload(_EmptySource(), requested);
      expect(outcome, isA<UploadCompleted>());
      expect((outcome as UploadCompleted).path, '/uploads/${example.group(2)}');
    }
  });

  test('README shifted range exhausts exactly the documented budget', () async {
    final first = capture(readme, r'alternativas van de `([^`]+)`');
    final last = capture(readme, r'alternativas van de `[^`]+` a `([^`]+)`');
    final session = _NamingSession(allOccupied: true);
    final outcome = await SftpUploadService.withOpener(
      () async => session,
    ).upload(_EmptySource(), '/uploads/foto(3).jpg');
    expect(outcome, isA<UploadDestinationExists>());
    expect(
      session.checked.length,
      int.parse(capture(readme, r'límite de (\d+) candidatos')),
    );
    expect(session.checked.first, '/uploads/foto(3).jpg');
    expect(session.checked[1], '/uploads/$first');
    expect(session.checked.last, '/uploads/$last');
    expect(session.openedWrite, isFalse);
  });

  test(
    'README Firebase client configuration paths contain API identifiers',
    () {
      expect(readme, contains('`android/app/google-services.json`'));
      expect(readme, contains('`lib/firebase_options.dart`'));
      final config =
          jsonDecode(read('android/app/google-services.json'))
              as Map<String, dynamic>;
      final clients = config['client'] as List<dynamic>;
      // Assert only presence, never expose a key in a failure diagnostic.
      final hasKey = clients.any(
        (client) => (client['api_key'] as List<dynamic>).any(
          (entry) =>
              entry['current_key'] is String &&
              (entry['current_key'] as String).isNotEmpty,
        ),
      );
      expect(hasKey, isTrue);
      final printsKey = clients.any(
        (client) => (client['api_key'] as List<dynamic>).any(
          (entry) =>
              entry['current_key'] is String &&
              (entry['current_key'] as String).isNotEmpty &&
              readme.contains(entry['current_key'] as String),
        ),
      );
      expect(printsKey, isFalse, reason: 'README must not print an API key');
      expect(
        RegExp(
          r"apiKey:\s*'[^']+'",
        ).hasMatch(codeOnly(read('lib/firebase_options.dart'))),
        isTrue,
      );
      expect(readme, contains('no secretos'));
      expect(readme, contains('restricciones de la clave API en Google Cloud'));
      expect(readme, contains('reglas de seguridad de Firebase'));
      expect(readme, contains('restringí tu propia clave'));
      expect(
        readme,
        contains('no prueban que la clave de este proyecto esté restringida'),
      );
    },
  );

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

// The actual upload service chooses names; this fake only models occupancy.
class _NamingSession implements SftpSession {
  _NamingSession({this.occupied = const {}, this.allOccupied = false});

  final Set<String> occupied;
  final bool allOccupied;
  final checked = <String>[];
  bool openedWrite = false;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    checked.add(path);
    if (allOccupied || occupied.contains(path)) return SftpFileAttrs();
    throw SftpStatusError(SftpStatusCode.noSuchFile, 'Missing');
  }

  @override
  Future<SftpWriteHandle> openWrite(String path) async {
    openedWrite = true;
    return _EmptyWriteHandle();
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {}

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected SFTP operation: ${invocation.memberName}',
  );
}

class _EmptyWriteHandle implements SftpWriteHandle {
  @override
  Future<void> writeChunk(Uint8List chunk, {required int offset}) async {}

  @override
  Future<void> close() async {}
}

class _EmptySource implements UploadSource {
  @override
  Future<int> length() async => 0;

  @override
  Stream<List<int>> openRead() => const Stream<List<int>>.empty();
}
