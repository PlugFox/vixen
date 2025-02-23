import 'dart:async';

import 'package:l/l.dart';
import 'package:vixen/src/bot.dart';
import 'package:vixen/src/captcha.dart';
import 'package:vixen/src/constant/constants.dart';
import 'package:vixen/src/database.dart';

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
  MessageHandler({required Set<int> chats, required Database db, required Bot bot, required CaptchaQueue captchaQueue})
    : _chats = chats,
      _db = db,
      _bot = bot,
      _captchaQueue = captchaQueue;

  final Set<int> _chats;
  final Database _db;
  final Bot _bot;
  final CaptchaQueue _captchaQueue;

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
      if (!_chats.contains(chatId)) return;
      l.d('Received message from $userId in chat $chatId');
      final type = Bot.getMessageType(message);
      final name = Bot.formatUsername(from);

      Future<void>(() async {
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
                ),
                mode: InsertMode.insertOrReplace,
              )
              .ignore();
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

        if (await _db.isBanned(userId)) {
          // Ban the user for additional 7 days
          _bot
              .banUser(
                chatId,
                userId,
                untilDate: DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000,
              )
              .ignore();
          return;
        }

        // Check, maybe the user is already has a captcha
        {
          final captcha =
              await (_db.select(_db.captchaMessage)
                    ..where((tbl) => tbl.userId.equals(userId) & tbl.chatId.equals(chatId))
                    ..limit(1))
                  .getSingleOrNull();
          // User already has a captcha
          if (captcha != null) return;
        }

        final mention = switch (name) {
          (name: _, $name: String v, username: _, $username: _) when v.isNotEmpty => '[$v](tg://user?id=$userId)',
          (name: _, $name: _, username: _, $username: String v) when v.isNotEmpty => '[@$v](tg://user?id=$userId)',
          _ => '[Unknown](tg://user?id=$userId)',
        };
        final captcha = await _captchaQueue.next();
        final String caption;
        {
          // Generate the caption for the message
          final captionBuffer =
              StringBuffer()
                ..writeln('👋 Hello, *$mention*\\!')
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
              ),
              mode: InsertMode.insertOrReplace,
            )
            .ignore();
        l.d('Sent captcha to $userId in chat $chatId');
      }).ignore();
    }
  }
}
