import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer';
import 'dart:io' as io;

import 'package:collection/collection.dart';
import 'package:intl/intl.dart';
import 'package:l/l.dart';
import 'package:vixen/src/reports.dart';
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

  // Handle the shutdown event
  l.i('Press [Ctrl+C] to exit');
  shutdownHandler(() async {
    l.i('Shutting down');
    io.exit(0);
  }).ignore();

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

        await startServer(arguments: arguments, database: db);
        l.i('Server is running on ${arguments.address}:${arguments.port}');

        final lastUpdateId = db.getKey<int>(updateIdKey);
        final bot = Bot(token: arguments.token, offset: lastUpdateId);
        bot
          ..addHandler(handler(arguments: arguments, bot: bot, db: db, captchaQueue: captchaQueue))
          ..start();
        l.i('Bot is running');

        sendReportsTimer(db, bot, arguments.chats);

        // TODO(plugfox): Metrics, Tests
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
              .map<LoggerCompanion>(
                (e) => LoggerCompanion.insert(
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
          await db.batch((batch) => batch.insertAll(db.logger, rows, mode: InsertMode.insertOrReplace));
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
    final deleted = await (db.delete(db.logger)..where((tbl) => tbl.time.isSmallerThanValue(weekAgo))).goAndReturn();
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

/// Handles the command line arguments.
Future<T?> shutdownHandler<T extends Object?>([final Future<T> Function()? onShutdown]) {
  //StreamSubscription<String>? userKeySub;
  StreamSubscription<io.ProcessSignal>? sigIntSub;
  StreamSubscription<io.ProcessSignal>? sigTermSub;
  final shutdownCompleter = Completer<T>.sync();
  var catchShutdownEvent = false;
  {
    Future<void> signalHandler(io.ProcessSignal signal) async {
      if (catchShutdownEvent) return;
      catchShutdownEvent = true;
      l.i('Received signal "$signal" - closing');
      T? result;
      try {
        //userKeySub?.cancel();
        sigIntSub?.cancel().ignore();
        sigTermSub?.cancel().ignore();
        result = await onShutdown?.call().catchError((Object error, StackTrace stackTrace) {
          l.e('Error during shutdown | $error', stackTrace);
          io.exit(2);
        });
      } finally {
        if (!shutdownCompleter.isCompleted) shutdownCompleter.complete(result);
      }
    }

    sigIntSub = io.ProcessSignal.sigint.watch().listen(signalHandler, cancelOnError: false);

    // SIGTERM is not supported on Windows.
    // Attempting to register a SIGTERM handler raises an exception.
    if (!io.Platform.isWindows)
      sigTermSub = io.ProcessSignal.sigterm.watch().listen(signalHandler, cancelOnError: false);
  }
  return shutdownCompleter.future;
}

void sendReportsTimer(Database db, Bot bot, Set<int> chats) {
  if (chats.isEmpty) return;
  const reportAtHour = 15; // Hour of the day to send the report
  final reports = Reports(db: db);

  void planReport() {
    final now = DateTime.now().toUtc();
    final nextReportTime = DateTime.utc(
      now.year,
      now.month,
      now.day,
      reportAtHour,
    ).add(now.hour >= reportAtHour ? const Duration(days: 1) : Duration.zero);

    final duration = nextReportTime.difference(now);

    Future<void> sendReports() async {
      try {
        final to = DateTime.now().toUtc(), from = to.subtract(const Duration(days: 1));
        final toUnix = to.millisecondsSinceEpoch ~/ 1000, fromUnix = from.millisecondsSinceEpoch ~/ 1000;

        // Delete the old report
        {
          final oldReports =
              await (db.delete(db.reportMessage)..where((tbl) => tbl.type.equals('report'))).goAndReturn();
          for (final report in oldReports) bot.deleteMessage(report.chatId, report.messageId).ignore();
        }

        final buffer = StringBuffer();
        for (final cid in chats) {
          // Get data from the database
          final mostActiveUsers = await reports
              .mostActiveUsers(from, to, cid)
              .then<ReportMostActiveUsers>((r) => r[cid] ?? const []);
          final verifiedUsers = await reports.verifiedUsers(from, to, cid);
          final bannedUsers = await reports.bannedUsers(from, to, cid);
          final sentMessagesCount = await db
              .customSelect(
                'SELECT COUNT(1) AS count '
                'FROM allowed_message '
                'WHERE date BETWEEN :from AND :to AND chat_id = :cid;',
                variables: [Variable.withInt(fromUnix), Variable.withInt(toUnix), Variable.withInt(cid)],
              )
              .getSingle()
              .then((r) => r.read<int>('count'));
          final deletedMessagesCount = await reports
              .deletedCount(from, to, cid)
              .then((r) => r.firstWhereOrNull((e) => e.cid == cid)?.count ?? 0);
          if (mostActiveUsers.isEmpty &&
              verifiedUsers.isEmpty &&
              bannedUsers.isEmpty &&
              sentMessagesCount == 0 &&
              deletedMessagesCount == 0)
            continue;

          // Create new report
          buffer
            ..writeln('*📅 Report for ${Bot.escapeMarkdownV2(DateFormat('dd MMM yyyy', 'en_US').format(from))}*')
            ..writeln();

          if (sentMessagesCount > 0) {
            buffer
              ..writeln('*📊 Messages count:* $sentMessagesCount')
              ..writeln();
          }

          if (deletedMessagesCount > 0) {
            buffer
              ..writeln('*🗑️ Deleted messages:* $deletedMessagesCount')
              ..writeln();
          }

          if (mostActiveUsers.isNotEmpty) {
            if (mostActiveUsers.length == 1) {
              buffer.write('*🥇 Most active user* ');
            } else {
              buffer.writeln('*🥇 Most active users:*');
            }
            for (final e in mostActiveUsers) {
              buffer.writeln('${Bot.userMention(e.uid, e.username)} \\(${e.count} messages\\)');
            }
            buffer.writeln();
          }

          if (verifiedUsers.isNotEmpty) {
            if (verifiedUsers.length == 1) {
              buffer.write('*✅ Verified user* ');
            } else {
              buffer.writeln('*✅ Verified ${verifiedUsers.length} users:*');
            }
            for (final e in verifiedUsers) {
              buffer.writeln('• ${Bot.userMention(e.uid, e.username)}');
            }
            buffer.writeln();
          }

          if (bannedUsers.isNotEmpty) {
            if (bannedUsers.length == 1) {
              buffer.write('*🚫 Banned user* ');
            } else {
              buffer.writeln('*🚫 Banned ${bannedUsers.length} users:*');
            }
            for (final e in bannedUsers) {
              buffer.writeln('• ${Bot.userMention(e.uid, e.username)} \\(${e.reason}\\)');
            }
            buffer.writeln();
          }

          // Send new report
          final messageId = await bot.sendMessage(cid, buffer.toString());
          db
              .into(db.reportMessage)
              .insert(
                ReportMessageCompanion.insert(
                  messageId: Value(messageId),
                  chatId: cid,
                  type: 'report',
                  createdAt: toUnix,
                  updatedAt: toUnix,
                ),
              )
              .ignore();

          // Clear the buffer
          buffer.clear();
        }
      } on Object catch (e, s) {
        l.w('Failed to send reports: $e', s);
      } finally {
        Timer(const Duration(hours: 1), planReport); // Reschedule the next report plan
        db.setKey(lastReportKey, DateTime.now().toUtc().toIso8601String());
      }
    }

    Timer(duration, sendReports);
  }

  planReport();
}
