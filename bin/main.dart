import 'dart:async';
import 'dart:collection';
import 'dart:developer';

import 'package:intl/intl.dart';
import 'package:l/l.dart';
import 'package:vixen/vixen.dart';

const String updateIdKey = 'update_id';

void main(List<String> args) {
  final logsBuffer = Queue<LogMessage>();
  l.listen(logsBuffer.add, cancelOnError: false);

  final arguments = Arguments.parse(args);
  l.capture(
    () => runZonedGuarded<void>(
      () async {
        l.i('Preparing database');
        final db = Database.lazy();
        collectLogs(db, logsBuffer);
        await db.refresh();
        l.i('Starting bot');
        final lastUpdateId = db.getKey<int>(updateIdKey);
        Bot(token: arguments.token, offset: lastUpdateId, onUpdate: handler(db)).start();
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

/// Collects logs from the buffer and saves them to the database every 5 seconds.
void collectLogs(Database db, Queue<LogMessage> buffer, {Duration interval = const Duration(seconds: 5)}) {
  void saveLogs(Timer timer) =>
      Future<void>(() async {
        try {
          if (buffer.isEmpty) return;
          final rows = buffer
              .map<LogTblCompanion>(
                (e) => LogTblCompanion.insert(
                  level: e.level.level,
                  message: e.message.toString(),
                  time: Value(e.timestamp.millisecondsSinceEpoch),
                  stack: switch (e) {
                    LogMessageError msg => Value<String?>(msg.stackTrace.toString()),
                    _ => const Value<String?>.absent(),
                  },
                ),
              )
              .toList(growable: false);
          buffer.clear();
          await db.batch((batch) => batch.insertAll(db.logTbl, rows, mode: InsertMode.insertOrReplace));
          //l.d('Inserted ${rows.length} logs');
        } on Object catch (e, s) {
          l.e('Failed to insert logs: $e', s);
        }
      }).ignore();
  Timer.periodic(interval, saveLogs);
}

/// Returns a handler that processes updates and saves the offset to the database.
void Function(int updateId, Map<String, Object?> update) handler(
  Database db, {
  Duration interval = const Duration(seconds: 5),
}) {
  final messageHandler = MessageHandler();

  var lastOffset = 0;

  // Periodically update the offset
  Timer.periodic(interval, (_) async {
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
