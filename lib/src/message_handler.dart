import 'dart:async';
import 'dart:collection';

import 'package:l/l.dart';
import 'package:vixen/src/bot.dart';
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
                    "first_name": "Username,
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
  MessageHandler({required Set<int> chats, required Database db, required Bot bot})
    : _chats = chats,
      _db = db,
      _bot = bot;

  final Set<int> _chats;
  final Database _db;
  final Bot _bot;

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
          await _bot.deleteMessages(chat, messages);
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
    _toDeleteScheduled = true;
    // Delay to allow for more messages to be added to the list
    Future<void>.delayed(const Duration(seconds: 1), _deleteMessages);
  }

  // --- Verified user --- //

  late final Future<Set<int>> _verifiedIds = (_db.selectOnly(_db.verified)
    ..addColumns([_db.verified.userId])).map((e) => e.read(_db.verified.userId)).get().then(HashSet<int>.from);

  /// Check if a user is verified.
  Future<bool> _isVerified(int userId) async {
    final verified = await _verifiedIds;
    return verified.contains(userId);
  }

  /// Verify a user.
  Future<void> _verifyUser(int userId, {int? verifiedAt, String? reason}) async {
    if ((await _verifiedIds).add(userId)) {
      // Insert the user into the database
      await _db
          .into(_db.verified)
          .insert(
            VerifiedCompanion.insert(
              userId: Value<int>(userId),
              verifiedAt: verifiedAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
              reason: Value.absentIfNull(reason),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      l.i('Verified user $userId');
    }
  }

  // --- Handle message --- //

  /// Handle a message.
  Future<void> call(Map<String, Object?> message) async {
    if (message case <String, Object?>{
      'message_id': int messageId,
      'date': int _, // date
      'from': Map<String, Object?> from,
      'chat': Map<String, Object?> chat,
    }) {
      final userId = from['id'], chatId = chat['id'];
      if (userId is! int || chatId is! int) return;
      if (!_chats.contains(chatId)) return;
      l.d('Received message from $userId in chat $chatId');
      if (await _isVerified(userId)) return;
      _scheduleDeleteMessage(chatId, messageId);
    }
  }
}
