import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the two conventions a sweep established, so the next surface does
/// not quietly reintroduce what the sweep removed.
///
/// Both are asserted over the SOURCE rather than over a rendered widget on
/// purpose: the defect they describe is a second place saying the same
/// thing differently, which no single widget test can see.
void main() {
  late final List<File> dartFiles;

  setUpAll(() {
    // Resolved from this file, not from the process cwd, matching
    // `readme_claims_test.dart`: the working directory a test runner picks
    // is not something a test should depend on.
    final here = File.fromUri(Platform.script).parent;
    final root = Directory(
      here.path.contains('/test/') ? here.path.split('/test/').first : '.',
    );
    dartFiles = Directory('${root.path}/lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(
      dartFiles,
      isNotEmpty,
      reason: 'the sweep is unverifiable if no sources were found',
    );
  });

  test('status icons come from one vocabulary, not from Icons directly', () {
    // AppTheme owns these four so two surfaces cannot drift apart while
    // meaning the same thing. They already had: a warning banner used
    // `warning_amber_rounded` while the transfer strip used
    // `warning_amber_outlined` for the identical idea.
    const banned = [
      'Icons.warning_amber_rounded',
      'Icons.warning_amber_outlined',
      'Icons.error_outline',
      'Icons.info_outline',
      'Icons.check_circle_outline',
    ];

    final offenders = <String>[];
    for (final file in dartFiles) {
      if (file.path.endsWith('app_theme.dart')) continue;
      final source = file.readAsStringSync();
      for (final icon in banned) {
        if (source.contains(icon)) {
          offenders.add('${file.path.split('/lib/').last} uses $icon');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'use AppTheme.warningIcon / errorIcon / infoIcon / successIcon.\n'
          'AgentStateStyle is a DIFFERENT axis and is exempt: it owns a '
          'per-state vocabulary, and an agent needing a human is not a '
          'warning banner.\n${offenders.join('\n')}',
    );
  });

  test('user-facing strings use a plain hyphen, not an em dash', () {
    // Requested from the device after reading one on screen. Comments keep
    // the em dash — this is about what the app SHOWS, not how the source
    // reads.
    final offenders = <String>[];
    for (final file in dartFiles) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('///') ||
            trimmed.startsWith('//') ||
            trimmed.startsWith('*')) {
          continue;
        }
        if (!line.contains('—')) continue;
        if (!line.contains("'") && !line.contains('"')) continue;
        offenders.add('${file.path.split('/lib/').last}:${i + 1}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'replace the em dash with "-" in these strings:\n'
          '${offenders.join('\n')}',
    );
  });
}
