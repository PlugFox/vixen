import 'package:l/l.dart';

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
