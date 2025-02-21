import 'dart:async';
import 'dart:developer';

import 'package:intl/intl.dart';
import 'package:l/l.dart';
import 'package:vixen/vixen.dart';

void main(List<String> args) {
  final arguments = Arguments.parse(args);
  l.capture(
    () => runZonedGuarded(
      () async {
        l.i('Preparing database');
        const updateIdKey = 'update_id';
        final db = Database.lazy();
        await db.refresh();
        l.i('Starting bot');
        final messageHandler = MessageHandler();
        var lastOffset = db.getKey<int>(updateIdKey);
        final bot = Bot(
          token: arguments.token,
          offset: lastOffset,
          onUpdate: (id, update) {
            l.d('Received update: $update');
            if (update['message'] case Map<String, Object?> message) {
              messageHandler(message);
            }
          },
        )..start();
        // Periodically update the offset
        Timer.periodic(const Duration(seconds: 5), (_) async {
          if (bot.offset > (lastOffset ?? 0)) {
            db.setKey(updateIdKey, bot.offset);
            lastOffset = bot.offset;
            l.d('Updated offset to ${bot.offset}');
          }
        });
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
