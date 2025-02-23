import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:l/l.dart';

Future<void> _runGitCommand(List<String> args) async {
  final result = await Process.run('git', args);
  if (result.exitCode == 0) return;
  l.e('Error running git ${args.join(" ")}: ${result.stderr}');
  exit(1);
}

/// dart run tool/tag.dart
void main() => runZonedGuarded<void>(
  () async {
    // Check if there any uncommitted or unpushed changes
    final statusResult = await Process.run('git', ['status', '--porcelain']);
    if ((statusResult.stdout as String).trim().isNotEmpty) {
      l.e('There are uncommitted changes');
      exit(1);
    }
    final aheadResult = await Process.run('git', ['rev-list', '--count', '--left-only', '@{u}...HEAD']);
    if ((aheadResult.stdout as String).trim() != '0') {
      l.e('There are unpushed changes');
      exit(1);
    }

    // Fetch pubspec.yaml file to get the version
    final pubspecFile = File('pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      l.w('File pubspec.yaml not found');
      exit(1);
    }
    final pubspecContent = pubspecFile.readAsLinesSync();
    final versionLine = pubspecContent.firstWhereOrNull((line) => line.trim().startsWith('version:'));
    if (versionLine == null || versionLine.isEmpty) {
      l.e('Version not found in pubspec.yaml');
      exit(1);
    }
    final version = versionLine.split(':')[1].trim();
    l.i('Found version: $version');
    final [major, minor, patch] = version.split('.').map(int.tryParse).toList(growable: false);
    if (major == null || minor == null || patch == null) {
      l.e('Invalid version format');
      exit(1);
    }

    // Check if the version is already tagged
    final result = await Process.run('git', ['tag', '-l', 'v$version']);
    if ((result.stdout as String).trim() == version) {
      l.e('Tag $version already exists');
      exit(1);
    }

    // Create tag
    await _runGitCommand(['tag', 'v$version']);
    l.i('Tag v$version created.');

    // Push tag
    await _runGitCommand(['push', 'origin', version]);
    l.i('Tag $version pushed to remote repository.');
  },
  (e, st) {
    l.e('Unexpected error: $e', st);
    exit(1);
  },
);
