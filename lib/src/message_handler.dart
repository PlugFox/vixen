import 'package:l/l.dart';

class MessageHandler {
  MessageHandler();

  void call(Map<String, Object?> message) {
    if (message case <String, Object?>{
      'message_id': int messageId,
      'date': int date,
      'from': Map<String, Object?> from,
      'chat': Map<String, Object?> chat,
    }) {
      final userId = from['id']! as int;
      final chatId = chat['id']! as int;
      l.d('Received message from $userId in chat $chatId');
    }
  }
}
