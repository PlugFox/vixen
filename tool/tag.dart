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
    // Check if there are any uncommitted or unpushed changes
    final statusResult = await Process.run('git', ['status', '--porcelain']);
    if ((statusResult.stdout as String).trim().isNotEmpty) {
      l.e('There are uncommitted changes.');
      exit(1);
    }
    final aheadResult = await Process.run('git', ['rev-list', '--count', '--left-only', '@{u}...HEAD']);
    if ((aheadResult.stdout as String).trim() != '0') {
      l.e('There are unpushed changes.');
      exit(1);
    }

    // Fetch pubspec.yaml file to get the version
    final pubspecFile = File('pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      l.w('File pubspec.yaml not found.');
      exit(1);
    }
    final pubspecContent = pubspecFile.readAsLinesSync();
    final versionLine = pubspecContent.firstWhereOrNull((line) => line.trim().startsWith('version:'));
    if (versionLine == null || versionLine.isEmpty) {
      l.e('Version not found in pubspec.yaml.');
      exit(1);
    }
    final version = versionLine.split(':')[1].trim();
    l.i('Found version: $version');

    // Validate version format
    final versionParts = version.split('.');
    if (versionParts.length != 3 || versionParts.any((e) => int.tryParse(e) == null)) {
      l.e('Invalid version format: $version');
      exit(1);
    }

    final tagName = 'v$version'; // Tag format: v1.2.3

    // Check if the tag already exists
    final tagResult = await Process.run('git', ['tag', '-l', tagName]);
    if (tagResult.stdout?.toString().trim() == tagName) {
      l.e('Tag $tagName already exists.');
      exit(1);
    }

    // Create tag
    await _runGitCommand(['tag', tagName]);
    l.i('Tag $tagName created.');

    // Push tag
    await _runGitCommand(['push', 'origin', tagName]);
    l.i('Tag $tagName pushed to remote repository.');
  },
  (e, st) {
    l.e('Unexpected error: $e', st);
    exit(1);
  },
);
