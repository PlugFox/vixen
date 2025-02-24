import 'dart:async';
import 'dart:convert';

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
      if (_chats.isNotEmpty && !_chats.contains(chatId)) return;
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
              }?.trim().toLowerCase();
          final length = text?.length ?? 0;
          // Check if the message is a spam by checking the hash of the message
          if (text != null && length >= 48) {
            final hash = xxh3.xxh3(utf8.encode(jsonEncode(message)));
            final entry = await _db.transaction(() async {
              final entry =
                  await (_db.select(_db.deletedMessageHash)
                        ..where((tbl) => tbl.length.equals(length) & tbl.hash.equals(hash))
                        ..limit(1))
                      .getSingleOrNull();
              // If the same length and hash, but different text - do nothing
              // Low probability of hash collision
              if (entry != null && entry.text != text) return null;
              await _db
                  .into(_db.deletedMessageHash)
                  .insertOnConflictUpdate(
                    DeletedMessageHashData(
                      length: length,
                      hash: hash,
                      count: (entry?.count ?? 0) + 1,
                      text: text,
                      updateAt: date,
                    ),
                  );
              return entry;
            });
            if (entry != null && entry.count >= 2 && entry.text == text) {
              // Ban the user for additional 7 days for spamming more than 3 times the same message
              final untilDate = DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000;
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
                    ..where((tbl) => tbl.userId.equals(userId) & tbl.chatId.equals(chatId))
                    ..limit(1))
                  .getSingleOrNull();
          // User already has a captcha - do nothing
          if (captcha != null) {
            l.d('User $userId already has a captcha in chat $chatId - do not send another one');
            return;
          }
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
