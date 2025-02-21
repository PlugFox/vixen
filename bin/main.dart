import 'dart:async';
import 'dart:developer';

import 'package:intl/intl.dart';
import 'package:l/l.dart';
import 'package:vixen/vixen.dart';

const String updateIdKey = 'update_id';

void main(List<String> args) {
  final arguments = Arguments.parse(args);
  l.capture(
    () => runZonedGuarded(
      () async {
        l.i('Preparing database');
        final db = Database.lazy();
        await db.refresh();
        l.i('Starting bot');
        Bot(token: arguments.token, offset: db.getKey<int>(updateIdKey), onUpdate: handler(db)).start();
      },
      (error, stackTrace) {
        l.e('An top level error occurred. $error', stackTrace);
        debugger(); // Set a breakpoint here
      },
    ),
    LogOptions(
      handlePrint: true,
      outputInRelease: true,
      printColors: true,
      overrideOutput: (event) {
        if (event.level.level > arguments.verbose.level) return null;
        //logsSink.writeln(output);
        return '[${event.level.prefix}] '
            '${DateFormat('dd.MM.yyyy HH:mm:ss').format(event.timestamp)} '
            '| ${event.message}';
      },
    ),
  );
}

void Function(int updateId, Map<String, Object?> update) handler(Database db) {
  final messageHandler = MessageHandler();

  var lastOffset = 0;

  // Periodically update the offset
  Timer.periodic(const Duration(seconds: 5), (_) async {
    if (lastOffset <= (db.getKey<int>(updateIdKey) ?? 0)) return;
    db.setKey(updateIdKey, lastOffset);
    l.d('Updated offset to $lastOffset');
  });

  return (updateId, update) {
    lastOffset = updateId;
    l.d('Received update: $update');
    if (update['message'] case Map<String, Object?> message) {
      messageHandler(message);
    }
  };
}
