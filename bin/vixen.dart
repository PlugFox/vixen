import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:collection/collection.dart';
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

        Timer.periodic(const Duration(days: 5), (_) async {
          await db.customStatement('VACUUM;'); // Compact the database every five days
          l.i('Database "${arguments.database}" is compacted');
        });

        await db.refresh();
        l.i('Database "${arguments.database}" is ready');

        final captchaQueue = CaptchaQueue(size: 24, length: 4, width: 480, height: 180);
        await captchaQueue.start();
        l.i('Captcha queue is running');

        final summarizer = switch (arguments.openaiKey) {
          String key when key.length >= 6 => Summarizer(
            key: key,
            db: db,
            model: arguments.openaiModel,
            url: arguments.openaiUrl,
          ),
          _ => null,
        };
        if (summarizer != null) l.i('Summarizer is initialized');

        final lastUpdateId = arguments.offset ?? db.getKey<int>(updateIdKey);
        final bot = Bot(token: arguments.token, offset: lastUpdateId);
        bot
          ..addHandler(handler(arguments: arguments, bot: bot, db: db, captchaQueue: captchaQueue))
          ..start();
        l.i('Bot is running');

        await startServer(arguments: arguments, database: db, bot: bot, summarizer: summarizer);
        l.i('Server is running on ${arguments.address}:${arguments.port}');

        sendReportsTimer(db, bot, arguments.chats, arguments.reportAtHour);
        l.i('Report sender is running');

        if (summarizer != null) {
          sendSummaryTimer(summarizer, db, bot, arguments.chats, arguments.reportAtHour);
          l.i('Summary sender is running');
        }

        updateChatInfos(db, bot, arguments.chats);
        l.i('Chat info updater is running');
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
        var message = switch (event.message) {
          String text => text,
          Object obj => obj.toString(),
        };
        if (kReleaseMode) {
          // Hide sensitive data in release mode
          if (arguments.secret case String key when key.isNotEmpty) message = message.replaceAll(key, '******');
          if (arguments.token case String key when key.isNotEmpty) message = message.replaceAll(key, '******');
          if (arguments.openaiKey case String key when key.isNotEmpty) message = message.replaceAll(key, '******');
        }
        return '[${event.level.prefix}] '
            '${DateFormat('dd.MM.yyyy HH:mm:ss').format(event.timestamp)} '
            '| $message';
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
                  time: Value(e.timestamp.millisecondsSinceEpoch ~/ 1000),
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
  final messageHandler = MessageHandler(
    chats: arguments.chats,
    db: db,
    bot: bot,
    captchaQueue: captchaQueue,
    clownChance: arguments.clownChance,
  );
  final callbackHandler = CallbackHandler(chats: arguments.chats, db: db, bot: bot, captchaQueue: captchaQueue);

  var lastOffset = 0;

  // Periodically update the offset
  Timer.periodic(interval, (_) async {
    if (lastOffset <= (db.getKey<int>(updateIdKey) ?? 0)) return;
    db.setKey(updateIdKey, lastOffset);
    l.d('Save updates offset `$lastOffset`');
  });

  // Periodically remove outdated captcha messages
  Timer.periodic(const Duration(seconds: captchaLifetime ~/ 3), (_) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final toDelete = await db.transaction<List<CaptchaMessageData>>(() async {
      final toDelete =
          await (db.select(db.captchaMessage)
            ..where((tbl) => tbl.expiresAt.isSmallerThanValue(now) & tbl.deleted.equals(0))).get();
      if (toDelete.isEmpty) return const [];
      final count = await (db.update(db.captchaMessage)
        ..where((tbl) => tbl.expiresAt.isSmallerThanValue(now) & tbl.deleted.equals(0))).write(
        CaptchaMessageCompanion(
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          deleted: const Value(1),
        ),
      );
      assert(count == toDelete.length, 'Failed to update ${toDelete.length} outdated captcha messages');
      return toDelete;
    });
    if (toDelete.isEmpty) return;
    for (final captcha in toDelete) bot.deleteMessage(captcha.chatId, captcha.messageId).ignore();
    l.i('Deleted ${toDelete.length} outdated captcha messages');
  });

  // Periodically remove expired bans
  Timer.periodic(const Duration(minutes: 5), (_) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final deleted = await (db.delete(db.banned)..where((tbl) => tbl.expiresAt.isSmallerThanValue(now))).goAndReturn();
    if (deleted.isEmpty) return;
    for (final ban in deleted) bot.unbanUser(ban.chatId, ban.userId, onlyIfBanned: true).ignore();
    l.i('Unbanned ${deleted.length} expired bans');
  });

  // Periodically delete outdated deleted records.
  Timer.periodic(const Duration(days: 1), (_) async {
    final yearAgo = DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch ~/ 1000;
    await db.batch((batch) {
      batch
        ..deleteWhere(
          db.deletedMessageHash,
          (tbl) => tbl.updateAt.isSmallerThanValue(yearAgo) & tbl.count.isSmallerThanValue(spamDuplicateLimit),
        )
        ..deleteWhere(db.deletedMessage, (tbl) => tbl.date.isSmallerThanValue(yearAgo));
    });
    l.i('Cleaned old deleted messages');
  });

  // Clear the old logs
  Timer.periodic(const Duration(days: 7), (_) async {
    final weekAgo = DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000;
    final deleted = await (db.delete(db.logger)..where((tbl) => tbl.time.isSmallerThanValue(weekAgo))).goAndReturn();
    if (deleted.isEmpty) return;
    l.i('Deleted ${deleted.length} old logs');
  });

  return (updateId, update) {
    assert(updateId > 0 && updateId + 1 > lastOffset, 'Invalid update id: $updateId');
    lastOffset = math.max(lastOffset, updateId + 1);
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

/// Periodically updates the chat information.
void updateChatInfos(Database db, Bot bot, Set<int> chats) {
  Future<void> update([_]) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final companions = <ChatInfoCompanion>[];
    for (final cid in chats) {
      try {
        final result = await bot.getChatInfo(cid);
        final type = result['type']?.toString();
        if (type == null) continue;
        final description = result['description']?.toString();
        final String? title;
        if (cid < 0) {
          title = result['title']?.toString() ?? 'Unknown';
        } else {
          final username = result['username']?.toString();
          final firstName = result['first_name']?.toString();
          final lastName = result['last_name']?.toString();
          title = (username ?? '$firstName $lastName').trim();
        }
        companions.add(
          ChatInfoCompanion.insert(
            chatId: Value<int>(cid),
            type: type,
            title: Value<String?>(title),
            description: Value<String?>(description),
            updatedAt: now,
          ),
        );
      } on Object catch (error, stackTrace) {
        l.w('Failed to update chat info for $cid: $error', stackTrace);
      }
    }
    if (companions.isEmpty) return;
    try {
      await db.batch((batch) => batch.insertAll(db.chatInfo, companions, mode: InsertMode.insertOrReplace));
      l.d('Updated ${companions.length} chat infos');
    } on Object catch (error, stackTrace) {
      l.e('Failed to update chat infos: $error', stackTrace);
    }
  }

  Timer.periodic(const Duration(hours: 1), update);

  Timer(const Duration(minutes: 1), update); // Initial update after 1 minute
}

/// Periodically sends reports to the chats.
void sendReportsTimer(Database db, Bot bot, Set<int> chats, int reportAtHour) {
  if (chats.isEmpty) return;
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

        for (final cid in chats) {
          ChatInfoData? chatInfo;
          try {
            chatInfo = await (db.select(db.chatInfo)..where((tbl) => tbl.chatId.equals(cid))).getSingleOrNull();

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
            final captchaCount = await db
                .customSelect(
                  'SELECT COUNT(1) AS count '
                  'FROM captcha_message AS tbl '
                  'WHERE tbl.updated_at BETWEEN :from AND :to '
                  'AND tbl.chat_id = :cid',
                  variables: [Variable.withInt(fromUnix), Variable.withInt(toUnix), Variable.withInt(cid)],
                )
                .getSingle()
                .then((r) => r.read<int>('count'));

            // Create new report
            final caption = TelegramMessageComposer.report(
              chatId: cid,
              date: to,
              sentMessagesCount: sentMessagesCount,
              deletedMessagesCount: deletedMessagesCount,
              captchaCount: captchaCount,
              mostActiveUsers: mostActiveUsers,
              verifiedUsers: verifiedUsers,
              bannedUsers: bannedUsers,
              chatInfo: chatInfo,
            );

            // Generate the chart
            final data = await reports.chartData(from: from, to: to, chatId: cid, random: false);
            final chart = await reports.chartPng(
              data: data,
              width: 720, // 480, // 1280
              height: 360, // 240, // 720
            );

            // Send new report
            final messageId = await bot.sendPhoto(
              chatId: cid,
              bytes: chart,
              filename: 'chart-${DateFormat('yyyy-MM-dd').format(to)}.png',
              caption: caption,
              notification: false,
            );

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
          } on Object catch (e, s) {
            l.w(
              'Failed to send report for chat $cid'
              '${switch (chatInfo?.title) {
                String title => '($title)',
                _ => '',
              }}: '
              '$e',
              s,
            );
          }
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

/// Periodically sends summaries to the chats.
void sendSummaryTimer(Summarizer summarizer, Database db, Bot bot, Set<int> chats, int reportAtHour) {
  if (chats.isEmpty) return;

  void planSummary() {
    final now = DateTime.now().toUtc();
    final nextReportTime = DateTime.utc(
      now.year,
      now.month,
      now.day,
      reportAtHour,
    ).add(now.hour >= reportAtHour ? const Duration(days: 1) : Duration.zero);

    final duration = nextReportTime.difference(now);

    Future<void> sendSummary() async {
      try {
        final to = DateTime.now().toUtc(), from = to.subtract(const Duration(days: 1));
        for (final cid in chats) {
          ChatInfoData? chatInfo;
          try {
            chatInfo = await (db.select(db.chatInfo)..where((tbl) => tbl.chatId.equals(cid))).getSingleOrNull();
            final topics = await summarizer(chatId: cid, from: from, to: to);
            if (topics.isEmpty) continue;
            final message = TelegramMessageComposer.summary(chatId: cid, topics: topics, date: to, chatInfo: chatInfo);
            if (message.isEmpty) continue;

            // Send new summary
            final _ = await bot.sendMessage(cid, message, disableNotification: true, protectContent: true);
          } on Object catch (e, s) {
            l.w(
              'Failed to send summary for chat $cid'
              '${switch (chatInfo?.title) {
                String title => '($title)',
                _ => '',
              }}: '
              '$e',
              s,
            );
          }
        }
      } on Object catch (e, s) {
        l.w('Failed to send summary: $e', s);
      } finally {
        Timer(const Duration(hours: 1), planSummary); // Reschedule the next summary plan
        db.setKey(lastSummaryKey, DateTime.now().toUtc().toIso8601String());
      }
    }

    Timer(duration + const Duration(seconds: 5), sendSummary);
  }

  planSummary();
}
