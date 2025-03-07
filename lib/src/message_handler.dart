import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:l/l.dart';
import 'package:vixen/src/bot.dart';
import 'package:vixen/src/captcha.dart';
import 'package:vixen/src/constant/constants.dart';
import 'package:vixen/src/database.dart';
import 'package:xxh3/xxh3.dart' as xxh3;

/*
{
    "ok": true,
    "result": [
        {
            "update_id": 123,
            "message": {
                "message_id": 123,
                "from": {
                    "id": 123,
                    "is_bot": false,
                    "first_name": "Username",
                    "username": "Username"
                },
                "chat": {
                    "id": -123,
                    "title": "Chat",
                    "type": "supergroup"
                },
                "date": 1740159731,
                "story": {
                    "chat": {
                        "id": 123,
                        "first_name": "Name",
                        "last_name": "Name",
                        "username": "name",
                        "type": "private"
                    },
                    "id": 123
                }
            }
        }
    ]
}
*/

class MessageHandler {
  MessageHandler({
    required Set<int> chats,
    required Database db,
    required Bot bot,
    required CaptchaQueue captchaQueue,
    required bool combotAntiSpam,
    required int clownChance,
    http.Client? httpClient,
    Uri? combotAntiSpamUri,
  }) : _chats = chats,
       _db = db,
       _bot = bot,
       _captchaQueue = captchaQueue,
       _combotAntiSpam = combotAntiSpam,
       _clownChance = clownChance.clamp(0, 100),
       _httpClient = httpClient ?? http.Client(),
       _combotAntiSpamUri = combotAntiSpamUri ?? Uri.parse('https://api.cas.chat/check');

  static final math.Random _rnd = math.Random();

  /// Chats to handle messages.
  final Set<int> _chats;

  /// SQLite database.
  final Database _db;

  /// Telegram bot.
  final Bot _bot;

  /// Queue of captchas to send to users.
  final CaptchaQueue _captchaQueue;

  /// Combot Anti-Spam enabled.
  final bool _combotAntiSpam;

  /// Chance to send a clown reaction to a message.
  final int _clownChance;

  /// HTTP client.
  final http.Client _httpClient;

  /// URI for Combot Anti-Spam.
  final Uri _combotAntiSpamUri;

  // --- Delete messages --- //

  final Map<int, List<DeletedMessageCompanion>> _toDelete = <int, List<DeletedMessageCompanion>>{};
  bool _toDeleteScheduled = false;

  /// Delete messages in the chats.
  void _deleteMessages() {
    _toDeleteScheduled = false;
    for (final MapEntry(key: int chat, value: List<DeletedMessageCompanion> list) in _toDelete.entries) {
      if (list.isEmpty) continue;
      final messages = list.toList(growable: false);
      list.clear();
      Future<void>(() async {
        try {
          _bot.deleteMessages(chat, messages.map((e) => e.messageId.value).toSet()).ignore();
          _db.batch((batch) => batch.insertAllOnConflictUpdate(_db.deletedMessage, messages)).ignore();
          l.d('Deleted ${messages.length} messages in chat $chat');
        } on Object catch (e, s) {
          l.w('Failed to delete ${messages.length} messages in chat $chat: $e', s);
        }
      }).ignore();
    }
  }

  /// Schedule a message to be deleted.
  void _scheduleDeleteMessage({
    required int messageId,
    required int chatId,
    required int userId,
    required int date,
    required String username,
    required String type,
  }) {
    _toDelete
        .putIfAbsent(chatId, () => <DeletedMessageCompanion>[])
        .add(
          DeletedMessageCompanion.insert(
            messageId: Value<int>(messageId),
            chatId: chatId,
            userId: userId,
            date: date,
            username: username,
            type: type,
          ),
        );
    if (_toDeleteScheduled) return;
    // Delay to allow for more messages to be added to the list and batch delete them
    _toDeleteScheduled = true;
    Timer(const Duration(milliseconds: 250), _deleteMessages);
  }

  /// Check if the user is a spammer with Combot Anti-Spam.
  /// Returns `true` if the user is not a spammer, `false` if the user is a spammer.
  /// https://cas.chat/api
  Future<bool> _checkWithCombotAntiSpam(int userId) async {
    if (!_combotAntiSpam) return true; // User is not a spammer
    try {
      final response = await _httpClient
          .get(_combotAntiSpamUri.replace(queryParameters: <String, String>{'user_id': userId.toString()}))
          .timeout(const Duration(seconds: 5));
      const allowedStatusCodes = {100, 101, 102, 103, 200, 201, 202, 203, 204, 205, 206, 207, 208, 226, 304};
      if (!allowedStatusCodes.contains(response.statusCode)) {
        l.d('Failed to check user $userId with Combot Anti-Spam');
        return true; // User is not a spammer
      }
      // {"ok":false,"description":"Record not found."}
      // {"ok":true,"result":{"reasons":[2],"offenses":1,"messages":null,"time_added":"2025-02-25T09:04:53.000Z"}}
      final codec = utf8.decoder.fuse(json.decoder);
      if (codec.convert(response.bodyBytes) case <String, Object?>{'ok': true}) {
        return false; // User is a spammer
      } else {
        return true; // User is not a spammer
      }
    } on TimeoutException {
      l.d('Failed to check user $userId with Combot Anti-Spam: Timeout exception');
      return true; // User is not a spammer
    } on Object catch (e, s) {
      l.w('Failed to check user $userId with Combot Anti-Spam: $e', s);
      return true; // User is not a spammer
    }
  }

  // --- Handle message --- //

  /// Handle a message.
  void call(Map<String, Object?> message) {
    if (message case <String, Object?>{
      'message_id': int messageId,
      'date': int date,
      'from': Map<String, Object?> from,
      'chat': Map<String, Object?> chat,
    }) {
      final userId = from['id'], chatId = chat['id'];
      if (userId is! int || chatId is! int) return;
      if (_chats.isNotEmpty && !_chats.contains(chatId)) return;
      l.d('Received message from $userId in chat $chatId');
      final type = Bot.getMessageType(message);
      final name = Bot.formatUsername(from);

      Future<void>(() async {
        /// Get the content of the message.
        final content =
            switch (type) {
              'text' => message['text']?.toString(),
              'photo' => message['caption']?.toString(),
              'audio' => message['caption']?.toString(),
              'video' => message['caption']?.toString(),
              'document' => message['caption']?.toString(),
              'animation' => message['caption']?.toString(),
              'voice' => message['caption']?.toString(),
              'paid_media' => message['caption']?.toString(),
              _ => null,
            }?.trim();

        if (await _db.isVerified(userId)) {
          // User is verified - update user activity and proceed
          _db
              .into(_db.allowedMessage)
              .insert(
                AllowedMessageCompanion.insert(
                  messageId: Value<int>(messageId),
                  userId: userId,
                  chatId: chatId,
                  date: date,
                  username: name.name ?? name.username ?? 'Unknown',
                  type: type,
                  replyTo: Value<int?>.absentIfNull(switch (message) {
                    <String, Object?>{'reply_to_message': <String, Object?>{'message_id': int v}} => v,
                    _ => null,
                  }),
                  length: Value<int>(content?.length ?? 0),
                  content: Value<String>(content ?? ''),
                ),
                mode: InsertMode.insertOrReplace,
              )
              .ignore();

          // Send a clown reaction to the message
          {
            final clownRng = _rnd.nextInt(100);
            if (_clownChance != 0 && clownRng < _clownChance)
              _bot.setMessageReaction(chatId: chatId, messageId: messageId, reaction: '🤡').ignore();
          }

          l.d('User $userId is verified, allowed message $messageId in chat $chatId');
          return;
        }

        // Delete the message because the user is not verified
        _scheduleDeleteMessage(
          messageId: messageId,
          chatId: chatId,
          userId: userId,
          date: date,
          username: name.name ?? name.username ?? 'Unknown',
          type: type,
        );

        // Ban the user for additional 7 days for sending a story, audio, video or voice
        if (const {'story', 'audio', 'video', 'voice'}.contains(type)) {
          final untilDate = DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000;
          _bot.banUser(chatId, userId, untilDate: untilDate).ignore();
          _db
              .banUser(
                chatId: chatId,
                userId: userId,
                name: name.name ?? name.username ?? 'Unknown',
                reason: 'Sending a $type without being verified',
                bannedAt: date,
                expiresAt: untilDate,
              )
              .ignore();
          l.i('Banned user $userId for sending a $type without being verified in chat $chatId');
          return;
        }

        // Ban the user for additional 7 days if the user is already banned
        if (await _db.isBanned(userId)) {
          _bot
              .banUser(
                chatId,
                userId,
                untilDate: DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000,
              )
              .ignore();
          l.i('Banned user $userId because the user is already banned in chat $chatId');
          return;
        }

        // Check if the message have a lot of duplicates as a spam
        {
          final text =
              content
                  ?.toLowerCase()
                  // Replace multiple spaces with a single space
                  .replaceAll(RegExp(r'\s+'), ' ')
                  // Remove all characters except letters, numbers and spaces
                  .replaceAll(
                    RegExp(
                      // Exclude all characters except letters, numbers and spaces
                      r'[^0-9a-zа-яё\s'
                      r'\.\,\+\-\*\/\=\!\?\;\:\(\)\"\@\#\%\$\₽\€\¥\₩\₴]',
                    ),
                    '',
                  )
                  // Trim the text
                  .trim();
          final length = text?.length ?? 0;
          // Check if the message is a spam by checking the hash of the message
          if (text != null && length >= 48) {
            final hash = xxh3.xxh3(utf8.encode(text));
            final entry = await _db.transaction(() async {
              final entry =
                  await (_db.select(_db.deletedMessageHash)
                        ..where((tbl) => tbl.length.equals(length) & tbl.hash.equals(hash))
                        ..limit(1))
                      .getSingleOrNull();
              // If the same length and hash, but different text - do nothing
              // Low probability of hash collision
              if (entry != null && entry.message != text) return null;
              await _db
                  .into(_db.deletedMessageHash)
                  .insertOnConflictUpdate(
                    DeletedMessageHashData(
                      length: length,
                      hash: hash,
                      count: (entry?.count ?? 0) + 1,
                      message: text,
                      updateAt: date,
                    ),
                  );
              return entry;
            });
            if (entry != null && entry.count >= spamDuplicateLimit && entry.message == text) {
              // Ban the user for spamming more than spamDuplicateLimit times the same message
              final untilDate =
                  DateTime.now().add(Duration(days: entry.count.clamp(7, 360))).millisecondsSinceEpoch ~/ 1000;
              _bot.banUser(chatId, userId, untilDate: untilDate).ignore();
              _db
                  .banUser(
                    chatId: chatId,
                    userId: userId,
                    name: name.name ?? name.username ?? 'Unknown',
                    reason: 'Spamming the same message (${entry.count} times) without being verified',
                    bannedAt: date,
                    expiresAt: untilDate,
                  )
                  .ignore();
              l.i('Banned user $userId for spamming the same message (${entry.count} times) in chat $chatId');
              return;
            }
          }
        }

        // Check, maybe the user is already has a captcha
        {
          final captcha =
              await (_db.select(_db.captchaMessage)
                    ..where((tbl) => tbl.userId.equals(userId) & tbl.chatId.equals(chatId) & tbl.deleted.equals(0))
                    ..limit(1))
                  .getSingleOrNull();
          // User already has a captcha - do nothing
          if (captcha != null) {
            l.d('User $userId already has a captcha in chat $chatId - do not send another one');
            return;
          }
        }

        // Check if the user is a spammer with Combot Anti-Spam
        {
          final isNotSpammer = await _checkWithCombotAntiSpam(userId);
          if (!isNotSpammer) {
            // Ban the user for spamming
            final untilDate = DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000;
            _bot.banUser(chatId, userId, untilDate: untilDate).ignore();
            _db
                .banUser(
                  chatId: chatId,
                  userId: userId,
                  name: name.name ?? name.username ?? 'Unknown',
                  reason: 'Combot Anti-Spam detected the user as a spammer without being verified',
                  bannedAt: date,
                  expiresAt: untilDate,
                )
                .ignore();
            l.i('Banned user $userId for being detected as a spammer by Combot Anti-Spam in chat $chatId');
            return;
          }
        }

        /* final mention = switch (name) {
          (name: _, $name: String v, username: _, $username: _) when v.isNotEmpty => '[$v](tg://user?id=$userId)',
          (name: _, $name: _, username: _, $username: String v) when v.isNotEmpty => '[@$v](tg://user?id=$userId)',
          _ => '[Unknown](tg://user?id=$userId)',
        }; */
        final mention = Bot.userMention(userId, switch (name) {
          (name: _, $name: String v, username: _, $username: _) when v.isNotEmpty => v,
          (name: _, $name: _, username: _, $username: String v) when v.isNotEmpty => v,
          _ => 'User',
        });
        final captcha = await _captchaQueue.next();
        final String caption;
        {
          // Generate the caption for the message
          final captionBuffer =
              StringBuffer()
                ..writeln('👋 Hello, *$mention* \\[`$userId`\\] \\!')
                ..writeln('\nPlease solve the _following captcha_ to continue chatting\\.');
          //captionBuffer.writeln(captcha.text);
          caption = captionBuffer.toString();
        }
        final msgId = await _bot.sendPhoto(
          chatId: chatId,
          bytes: captcha.image,
          filename: 'captcha.png',
          caption: caption,
          notification: true,
          reply: defaultCaptchaKeyboard,
        );
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        _db
            .into(_db.captchaMessage)
            .insert(
              CaptchaMessageCompanion.insert(
                messageId: Value<int>(msgId),
                userId: userId,
                chatId: chatId,
                caption: caption,
                solution: captcha.text,
                input: '',
                createdAt: now,
                updatedAt: now,
                expiresAt: now + captchaLifetime,
                deleted: const Value<int>(0),
              ),
              mode: InsertMode.insertOrReplace,
            )
            .ignore();
        l.d('Sent captcha to $userId in chat $chatId');
      }).ignore();
    }
  }
}
