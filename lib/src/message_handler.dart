import 'dart:async';
import 'dart:collection';

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

  final Map<int, List<int>> _toDelete = <int, List<int>>{};
  bool _toDeleteScheduled = false;

  /// Delete messages in the chats.
  void _deleteMessages() {
    _toDeleteScheduled = false;
    for (final MapEntry(key: int chat, value: List<int> ids) in _toDelete.entries) {
      if (ids.isEmpty) continue;
      final messages = HashSet<int>.of(ids);
      ids.clear();
      Future<void>(() async {
        try {
          _bot.deleteMessages(chat, messages).ignore();
          l.d('Deleted ${messages.length} messages in chat $chat');
        } on Object catch (e, s) {
          l.w('Failed to delete ${messages.length} messages in chat $chat: $e', s);
        }
      }).ignore();
    }
  }

  /// Schedule a message to be deleted.
  void _scheduleDeleteMessage(int chatId, int messageId) {
    _toDelete.putIfAbsent(chatId, () => <int>[]).add(messageId);
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
      Future<void>(() async {
        if (await _db.isVerified(userId)) {
          // User is verified - update user activity and proceed
          _db
              .into(_db.message)
              .insert(
                MessageCompanion.insert(
                  messageId: Value<int>(messageId),
                  userId: userId,
                  chatId: chatId,
                  date: date,
                  type: Bot.getMessageType(message),
                ),
                mode: InsertMode.insertOrReplace,
              )
              .ignore();
          return;
        }

        _scheduleDeleteMessage(chatId, messageId); // Delete the message because the user is not verified

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

        final captcha = await _captchaQueue.next();
        final name = switch (Bot.formatUsername(from)) {
          (name: _, escaped: String escaped, username: false) => escaped,
          (name: _, escaped: String escaped, username: true) => '@$escaped',
        };
        final String caption;
        {
          // Generate the caption for the message
          final captionBuffer =
              StringBuffer()
                ..writeln('👋 Hello, *[$name](tg://user?id=$userId)*\\!')
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
