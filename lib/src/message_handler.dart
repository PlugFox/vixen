import 'package:l/l.dart';

// TODO(plugfox): Database, Captcha queue, Admin commands, Metrics, Tests
// Mike Matiunin <plugfox@gmail.com>, 22 February 2025

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
  MessageHandler();

  void call(Map<String, Object?> message) {
    if (message case <String, Object?>{
      'message_id': int _, // messageId
      'date': int _, // date
      'from': Map<String, Object?> from,
      'chat': Map<String, Object?> chat,
    }) {
      final userId = from['id'], chatId = chat['id'];
      if (userId is! int || chatId is! int) return;
      l.d('Received message from $userId in chat $chatId');
    }
  }
}
