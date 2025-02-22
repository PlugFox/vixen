import 'package:l/l.dart';
import 'package:vixen/src/bot.dart';
import 'package:vixen/src/captcha.dart';
import 'package:vixen/src/constant/constants.dart';
import 'package:vixen/src/database.dart';

/// Callback handler class
class CallbackHandler {
  CallbackHandler({required Set<int> chats, required Database db, required Bot bot, required CaptchaQueue captchaQueue})
    : _chats = chats,
      _db = db,
      _bot = bot,
      _captchaQueue = captchaQueue;

  final Set<int> _chats;
  final Database _db;
  final Bot _bot;
  final CaptchaQueue _captchaQueue;

  /// Handles the callback
  void call(Map<String, Object?> callback) {
    if (callback case <String, Object?>{
      'id': String callbackQueryId,
      'from': Map<String, Object?> from,
      'message': <String, Object?>{
        'message_id': int messageId,
        'date': int _, // date
        'chat': Map<String, Object?> chat,
      },
      'data': String data,
    }) {
      final userId = from['id'], chatId = chat['id'];
      if (userId is! int || chatId is! int) return;
      if (!_chats.contains(chatId)) return;
      l.d('Callback from $userId in $chatId: $data');
      if (data.startsWith(kbCaptcha))
        Future<void>(() async {
          final captcha =
              await (_db.select(_db.captchaMessage)
                    ..where((tbl) => tbl.messageId.equals(messageId))
                    ..limit(1))
                  .getSingleOrNull();
          if (captcha == null) {
            l.w('Captcha not found for message $messageId', StackTrace.current);
            _bot.answerCallbackQuery(callbackQueryId, 'Captcha not found').ignore();
            _bot.deleteMessage(chatId, messageId).ignore();
            return;
          } else if (captcha.userId != userId || captcha.chatId != chatId) {
            _bot.answerCallbackQuery(callbackQueryId, 'This captcha is not for you').ignore();
            return;
          }
          if (data == kbCaptchaRefresh) {
            // Refresh the captcha
            _bot.answerCallbackQuery(callbackQueryId, 'Refreshing captcha').ignore();
            final newCaptcha = await _captchaQueue.next();
            _bot
                .editMessageMedia(
                  chatId: chatId,
                  messageId: messageId,
                  bytes: newCaptcha.image,
                  filename: 'captcha.png',
                  caption: captcha.caption,
                  reply: defaultCaptchaKeyboard,
                )
                .ignore();
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            _db
                .update(_db.captchaMessage)
                .replace(
                  captcha.copyWith(
                    input: '',
                    solution: newCaptcha.text,
                    updatedAt: now,
                    expiresAt: now + captchaLifetime,
                  ),
                )
                .ignore();
            l.d('Refreshed captcha for $userId in $chatId');
            return;
          }
          // Handle the captcha input from the keyboard
          var input = captcha.input;
          switch (data) {
            case kbCaptchaBackspace:
              input = input.isEmpty ? '' : input.substring(0, input.length - 1);
            case kbCaptchaOne:
              input += '1';
            case kbCaptchaTwo:
              input += '2';
            case kbCaptchaThree:
              input += '3';
            case kbCaptchaFour:
              input += '4';
            case kbCaptchaFive:
              input += '5';
            case kbCaptchaSix:
              input += '6';
            case kbCaptchaSeven:
              input += '7';
            case kbCaptchaEight:
              input += '8';
            case kbCaptchaNine:
              input += '9';
            case kbCaptchaZero:
              input += '0';
            default:
              l.w('Invalid captcha input: $data', StackTrace.current);
              _bot.answerCallbackQuery(callbackQueryId, 'Invalid input').ignore();
              return;
          }
          if (input.length > captcha.solution.length) input = input.substring(0, captcha.solution.length);
          if (input == captcha.solution) {
            _bot.answerCallbackQuery(callbackQueryId, 'Correct!').ignore();
            _bot.deleteMessage(chatId, messageId).ignore();
            (_db.delete(_db.captchaMessage)..whereSamePrimaryKey(captcha)).go().ignore();
            // TODO(plugfox): Verify the user
            // Mike Matiunin <plugfox@gmail.com>, 22 February 2025
            return;
          } else {
            final currentInputText =
                input.isNotEmpty
                    ? 'Current input: ${input.split('').map((i) => _numbers[i] ?? i).join(' ')}'
                    : 'Current input: empty';
            _bot.answerCallbackQuery(callbackQueryId, currentInputText).ignore();
            if (input != captcha.input) {
              _bot
                  .editPhotoCaption(
                    chatId: chatId,
                    messageId: messageId,
                    caption: input.isEmpty ? captcha.caption : '${captcha.caption}\n\n_${currentInputText}_',
                    reply: defaultCaptchaKeyboard,
                  )
                  .ignore();
            }
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            _db
                .update(_db.captchaMessage)
                .replace(captcha.copyWith(input: input, updatedAt: now, expiresAt: now + captchaLifetime))
                .ignore();
            return;
          }
        });
    }
  }
}

const Map<String, String> _numbers = <String, String>{
  '0': '0️⃣',
  '1': '1️⃣',
  '2': '2️⃣',
  '3': '3️⃣',
  '4': '4️⃣',
  '5': '5️⃣',
  '6': '6️⃣',
  '7': '7️⃣',
  '8': '8️⃣',
  '9': '9️⃣',
};
