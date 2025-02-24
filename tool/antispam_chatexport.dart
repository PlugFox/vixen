import 'dart:convert';
import 'dart:io';

import 'package:vixen/src/anti_spam.dart';

void err(Object? message) => stderr.writeln(message);

void info(Object? message) => stdout.writeln(message);

extension type Message(Map<String, Object?> _map) {
  int get id => _map['id'] as int;
  String get type => _map['type'] as String;
  String get date => _map['date'] as String;
  String get from => _map['from']?.toString() ?? _map['from_id']?.toString() ?? 'Unknown';
  String get text => switch (_map['text']) {
    String s => s,
    Iterable<Object?> l => l.whereType<String>().join(' '),
    _ => '',
  };
}

/// Check `ChatExport.json` file for spam messages
void main(List<String> arguments) {
  final file = File('ChatExport.json');
  if (!file.existsSync()) {
    err('File ChatExport.json not found.');
    exit(1);
  }
  final messages = (jsonDecode(file.readAsStringSync())!['messages'] as List)
      .whereType<Map<String, Object?>>()
      .map(Message.new)
      .where((e) => e.id >= 0 && e.text.isNotEmpty);

  final spam = <Map<String, Object?>>[];

  var messagesCount = 0;
  var spamCount = 0;
  final reasons = <String, int>{};
  for (final message in messages) {
    messagesCount++;
    final result = AntiSpam.checkSync(message.text);
    if (!result.spam) continue;
    spamCount++;
    reasons.update(result.reason, (v) => v + 1, ifAbsent: () => 1);
    spam.add({
      'reason': result.reason,
      'id': message.id,
      'type': message.type,
      'date': message.date,
      'from': message.from,
      'text': message.text,
    });
  }
  final reasonsEntries = reasons.entries.toList(growable: false)..sort((a, b) => b.value.compareTo(a.value));
  final string = jsonEncode({
    'messages': messagesCount,
    'spam': spamCount,
    'reasons': {for (final entry in reasonsEntries) entry.key: entry.value},
    'items': spam,
  });
  File('ChatExport_spam.json').writeAsStringSync(string);
  info('Messages: $messagesCount, Spam: $spamCount');
  info('Spam messages saved to ChatExport_spam.json');
  exit(0);
}
