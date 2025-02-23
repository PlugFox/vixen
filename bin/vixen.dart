import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer';
import 'dart:io' as io;

import 'package:intl/intl.dart';
import 'package:l/l.dart';
import 'package:vixen/vixen.dart';

/// The main entry point of the bot.
/// Initializes the database, starts the bot, and collects logs.
///
/// The bot token is required to start the bot.
/// The token can be obtained from the BotFather on Telegram.
///
/// How to run:
/// ```shell
/// dart bin/vixen.dart --token <bot_token>
/// ```
///
/// How to compile:
/// ```shell
/// dart compile exe bin/vixen.dart -o bin/main.run
/// bin/main.run --token <bot_token>
/// ```
void main(List<String> args) {
  final logsBuffer = Queue<LogMessage>();
  l.listen(logsBuffer.add, cancelOnError: false);

  final arguments = Arguments.parse(args);

  if (arguments.chats.isEmpty) {
    io.stderr.writeln('No chat IDs provided');
    io.exit(2);
  }

  l.capture(
    () => runZonedGuarded<void>(
      () async {
        final db = Database.lazy(path: arguments.database); // Open the database
        await db.customStatement('VACUUM;'); // Compact the database
        collectLogs(db, logsBuffer); // Store logs in the database every 5 seconds
        await db.refresh();
        l.i('Database "${arguments.database}" is ready');

        final captchaQueue = CaptchaQueue(size: 24, length: 4, width: 480, height: 180);
        await captchaQueue.start();
        l.i('Captcha queue is running');

        final srv = await startServer(arguments: arguments, database: db);
        l.i('Server is running on ${srv.address.address}:${srv.port}');

        final lastUpdateId = db.getKey<int>(updateIdKey);
        final bot = Bot(token: arguments.token, offset: lastUpdateId);
        bot
          ..addHandler(handler(arguments: arguments, bot: bot, db: db, captchaQueue: captchaQueue))
          ..start();
        l.i('Bot is running');

        // TODO(plugfox): Admin commands, Metrics, Tests
        // Mike Matiunin <plugfox@gmail.com>, 22 February 2025
      },
      (error, stackTrace) {
        l.e('An top level error occurred. $error', stackTrace);
        debugger(); // Set a breakpoint here
      },
    ),
    LogOptions(
      handlePrint: true,
      outputInRelease: true,
      printColors: false,
      overrideOutput: (event) {
        //logsBuffer.add(event);
        if (event.level.level > arguments.verbose.level) return null;
        return '[${event.level.prefix}] '
            '${DateFormat('dd.MM.yyyy HH:mm:ss').format(event.timestamp)} '
            '| ${event.message}';
      },
    ),
  );
}

/// Collects logs from the buffer and saves them to the database every 5 seconds.
void collectLogs(Database db, Queue<LogMessage> buffer, {Duration interval = const Duration(seconds: 5)}) {
  Object? toEncodable(Object? obj) => switch (obj) {
    DateTime dt => dt.toIso8601String(),
    Exception e => e.toString(),
    Error e => e.toString(),
    StackTrace st => st.toString(),
    _ => obj.toString(),
  };

  Value<String> encodeContext(Map<String, Object?>? context) {
    if (context == null || context.isEmpty) return const Value.absent();
    try {
      return Value(jsonEncode(context, toEncodable: toEncodable));
    } on Object {
      debugger(); // Set a breakpoint here
      l.w('Failed to encode context');
      return const Value.absent();
    }
  }

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
                  context: encodeContext(e.context),
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
void Function(int updateId, Map<String, Object?> update) handler({
  required Arguments arguments,
  required Bot bot,
  required Database db,
  required CaptchaQueue captchaQueue,
  Duration interval = const Duration(seconds: 5),
}) {
  final messageHandler = MessageHandler(chats: arguments.chats, db: db, bot: bot, captchaQueue: captchaQueue);
  final callbackHandler = CallbackHandler(chats: arguments.chats, db: db, bot: bot, captchaQueue: captchaQueue);

  var lastOffset = 0;

  // Periodically update the offset
  Timer.periodic(interval, (_) async {
    if (lastOffset <= (db.getKey<int>(updateIdKey) ?? 0)) return;
    db.setKey(updateIdKey, lastOffset);
    l.d('Save updates offset `$lastOffset`');
  });

  // Periodically remove outdated captcha messages
  Timer.periodic(const Duration(seconds: captchaLifetime ~/ 10), (_) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final deleted =
        await (db.delete(db.captchaMessage)..where((tbl) => tbl.expiresAt.isSmallerThanValue(now))).goAndReturn();
    if (deleted.isEmpty) return;
    for (final captcha in deleted) bot.deleteMessage(captcha.chatId, captcha.messageId).ignore();
    l.i('Deleted ${deleted.length} outdated captcha messages');
  });

  // Periodically remove expired bans
  Timer.periodic(const Duration(minutes: 5), (_) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final deleted = await (db.delete(db.banned)..where((tbl) => tbl.expiresAt.isSmallerThanValue(now))).goAndReturn();
    if (deleted.isEmpty) return;
    for (final ban in deleted) bot.unbanUser(ban.chatId, ban.userId, onlyIfBanned: true).ignore();
    l.i('Unbanned ${deleted.length} expired bans');
  });

  // Clear the old logs
  Timer.periodic(const Duration(days: 7), (_) async {
    final weekAgo = DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000;
    final deleted = await (db.delete(db.logTbl)..where((tbl) => tbl.time.isSmallerThanValue(weekAgo))).goAndReturn();
    if (deleted.isEmpty) return;
    l.i('Deleted ${deleted.length} old logs');
  });

  return (updateId, update) {
    lastOffset = updateId;
    l.d('Received update', update);
    if (update['message'] case Map<String, Object?> message) {
      messageHandler(message);
    } else if (update['callback_query'] case Map<String, Object?> callback) {
      callbackHandler(callback);
    } else if (kDebugMode) {
      l.d('Unknown update type: $update');
      debugger(); // Set a breakpoint here
    }
  };
}
