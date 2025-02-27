import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:l/l.dart';

final Converter<List<int>, Map<String, Object?>> _jsonDecoder =
    utf8.decoder.fuse(json.decoder).cast<List<int>, Map<String, Object?>>();

final Converter<Object?, List<int>> _jsonEncoder = json.encoder.fuse(utf8.encoder);

typedef OnUpdateHandler = void Function(int id, Map<String, Object?> update);

class Bot {
  Bot({required String token, http.Client? client, int? offset, Duration interval = const Duration(seconds: 30)})
    : _baseUri = Uri.parse('https://api.telegram.org/bot$token'),
      _client = client ?? http.Client(),
      _offset = offset ?? 0,
      _interval = interval,
      _handlers = <OnUpdateHandler>[];

  final Uri _baseUri;
  final http.Client _client; // The HTTP client
  final Duration _interval; // The polling interval

  /// The offset of the last update.
  int get offset => _offset;
  int _offset; // The offset of the last update
  Completer<void>? _poller; // The poller completer

  final List<OnUpdateHandler> _handlers; // The list of handlers

  /// Escape special characters in a MarkdownV2 string.
  static String escapeMarkdownV2(String text) {
    const specialChars = r'_*\[\]()~`>#+\-=|{}.!';
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      var char = String.fromCharCode(rune);
      if (specialChars.contains(char)) {
        buffer.write(r'\');
      }
      buffer.write(char);
    }
    return buffer.toString();
  }

  /// Format a user mention as a link.
  static String userMention(int uid, String username) => '[${escapeMarkdownV2(username)}](tg://user?id=$uid)';

  /// Format a username from a user object.
  /// [name] - The name of the user if available otherwise the username.
  /// [escaped] - The escaped name of the user.
  /// [username] - Whether the name is a username.
  static ({String? name, String? username, String? $name, String? $username}) formatUsername(
    Map<String, Object?> user,
  ) {
    final fullName =
        switch ((user['first_name'], user['last_name'])) {
          ('', '') || (null, null) => '',
          (String first, '') || (String first, null) => first,
          ('', String second) || (null, String second) => second,
          (String first, String second) => '$first $second',
          _ => '',
        }.trim();
    final name = fullName.isEmpty ? null : fullName;
    final username = switch (user['username']) {
      String value when value.isNotEmpty => value,
      _ => null,
    };
    final $name = name != null ? escapeMarkdownV2(name) : null;
    final $username = username != null ? escapeMarkdownV2(username) : null;
    return (name: name, username: username, $name: $name, $username: $username);
  }

  /// Get the type of a message.
  static String getMessageType(Map<String, Object?> message) {
    const types = <String>{
      'text',
      'photo',
      'video',
      'document',
      'audio',
      'voice',
      'sticker',
      'animation',
      'video_note',
      'paid_media',
      'contact',
      'location',
      'venue',
      'poll',
      'dice',
      'game',
      'forward_origin',
      'story',
      'invoice',
      'successful_payment',
    };
    for (final type in types) if (message.containsKey(type)) return type;
    return 'unknown';
  }

  /// Add a handler to be called when an update is received.
  void addHandler(OnUpdateHandler handler) {
    _handlers.add(handler);
  }

  /// Remove a handler from the list of handlers.
  void removeHandler(OnUpdateHandler handler) {
    _handlers.remove(handler);
  }

  @pragma('vm:prefer-inline')
  Uri _buildMethodUri(String method) => _baseUri.replace(path: '${_baseUri.path}/$method');

  /// Fetch updates from the Telegram API.
  @pragma('vm:prefer-inline')
  Future<List<({int id, Map<String, Object?> update})>> _getUpdates(Uri url) async {
    final response = await _client.get(url);
    if (response.statusCode != 200) {
      l.w('Failed to fetch updates: status code ${response.statusCode}', StackTrace.current);
      return const [];
    }
    final update = _jsonDecoder.convert(response.bodyBytes);
    if (update['ok'] != true) {
      l.w('Failed to fetch updates: not ok', StackTrace.current, update);
      return const [];
    }
    final result = update['result'];
    if (result is! List) {
      l.w('Failed to fetch updates: wrong result type', StackTrace.current, update);
      return const [];
    }
    return result
      .whereType<Map<String, Object?>>()
      .map<({int id, Map<String, Object?> update})>(
        (u) => (
          id: switch (u['update_id']) {
            int id => id,
            _ => -1,
          },
          update: u,
        ),
      )
      .where((u) => u.id >= 0)
      .toList(growable: false)..sort((a, b) => a.id.compareTo(b.id));
  }

  /// Handle updates by calling all the handlers for each update.
  @pragma('vm:prefer-inline')
  void _handleUpdates(List<({int id, Map<String, Object?> update})> updates) {
    for (final u in updates) {
      assert(u.id >= 0 && u.id + 1 > _offset, 'Invalid update ID: ${u.id}');
      _offset = math.max(u.id + 1, _offset);
      for (final handler in _handlers) {
        try {
          handler(u.id, u.update);
        } on Object catch (error, stackTrace) {
          l.e('An error occurred while handling update #${u.id}: $error', stackTrace, {'id': u.id, 'update': u});
          continue;
        }
      }
    }
  }

  /// Start polling for [updates](https://core.telegram.org/bots/api#getupdates).
  /// [types] - The [types of updates](https://core.telegram.org/bots/api#update) to fetch.
  /// By default, it fetches messages and callback queries.
  void start({Set<String> types = const <String>{'message', 'callback_query'}}) => runZonedGuarded<void>(
    () {
      stop(); // Stop any previous poller
      final allowedUpdates = jsonEncode(types.toList(growable: false));
      final url = _buildMethodUri('getUpdates');
      final poller = _poller = Completer<void>()..future.ignore();
      final throttleStopwatch = Stopwatch()..start();
      Future<void>(() async {
        while (true) {
          try {
            if (poller.isCompleted) return;
            throttleStopwatch.reset();
            final updates = await _getUpdates(
              url.replace(
                queryParameters: {
                  if (_offset >= 0) 'offset': _offset.toString(),
                  'limit': '100',
                  'timeout': _interval.inSeconds.toString(),
                  'allowed_updates': allowedUpdates,
                },
              ),
            ).timeout(_interval * 2);
            if (poller.isCompleted) return;
            _handleUpdates(updates);
            // Throttle the polling to avoid hitting the rate limit
            if (throttleStopwatch.elapsed < const Duration(milliseconds: 250)) {
              l.d('Throttling polling');
              await Future<void>.delayed(const Duration(seconds: 1) - throttleStopwatch.elapsed);
            }
          } on Object catch (error, stackTrace) {
            l.e('An error occurred while fetching updates: $error', stackTrace);
          }
        }
      });
    },
    (error, stackTrace) {
      l.e('An error occurred while polling for updates: $error', stackTrace);
    },
  );

  /// Stop polling for updates.
  void stop() {
    _poller?.complete();
  }

  /// Send a message to a chat.
  Future<int> sendMessage(
    int chatId,
    String text, {
    bool disableNotification = true,
    bool protectContent = true,
  }) async {
    final url = _buildMethodUri('sendMessage');
    final response = await _client.post(
      url,
      body: _jsonEncoder.convert({
        'chat_id': chatId,
        'text': text,
        'parse_mode': 'MarkdownV2',
        'disable_notification': disableNotification,
        'protect_content': protectContent,
      }),
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode != 200) throw Exception('Failed to send message: status code ${response.statusCode}');
    final result = _jsonDecoder.convert(response.bodyBytes);
    if (result case <String, Object?>{'ok': true, 'result': <String, Object?>{'message_id': int messageId}}) {
      return messageId;
    } else if (result case <String, Object?>{'ok': false, 'description': String description}) {
      l.w('Failed to send message: $description', StackTrace.current, result);
      throw Exception('Failed to send message: $description');
    } else {
      l.w('Failed to send message', StackTrace.current, result);
      throw Exception('Failed to send message');
    }
  }

  /// Send a photo to a chat.
  Future<int> sendPhoto({
    required int chatId,
    required List<int> bytes,
    required String filename,
    String? caption,
    bool notification = true,
    String? reply,
  }) async {
    final url = _buildMethodUri('sendPhoto');

    var request = http.MultipartRequest('POST', url);
    request.fields
      ..['chat_id'] = chatId.toString()
      ..['protect_content'] = 'true'
      ..['disable_notification'] = notification ? 'false' : 'true';
    if (caption != null)
      request.fields
        ..['parse_mode'] = 'MarkdownV2'
        ..['caption'] = caption
        ..['show_caption_above_media'] = 'true';
    if (reply != null) request.fields['reply_markup'] = reply;
    request.files.add(http.MultipartFile.fromBytes('photo', bytes, filename: filename));
    final response = await request.send();
    final responseBody = await response.stream.toBytes();
    final result = _jsonDecoder.convert(responseBody);
    if (result case <String, Object?>{'ok': true, 'result': <String, Object?>{'message_id': int messageId}}) {
      return messageId;
    } else if (result case <String, Object?>{'ok': false, 'description': String description}) {
      l.w('Failed to send photo: $description', StackTrace.current, result);
      throw Exception('Failed to send photo: $description');
    } else {
      l.w('Failed to send photo', StackTrace.current, result);
      throw Exception('Failed to send photo');
    }
  }

  /// Edit a photo caption in a chat.
  Future<void> editPhotoCaption({required int chatId, required int messageId, String? caption, String? reply}) async {
    final url = _buildMethodUri('editMessageCaption');
    final response = await _client.post(
      url,
      body: _jsonEncoder.convert({
        'chat_id': chatId,
        'message_id': messageId,
        if (caption != null) ...<String, Object?>{
          'parse_mode': 'MarkdownV2',
          'caption': caption,
          'show_caption_above_media': true,
        },
        if (reply != null) 'reply_markup': reply,
      }),
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode == 200 || response.statusCode == 400) return;
    l.w('Failed to edit photo caption: status code ${response.statusCode}', StackTrace.current);
    throw Exception('Failed to edit photo caption: status code ${response.statusCode}');
  }

  /// Edit a message in a chat.
  Future<void> editMessageMedia({
    required int chatId,
    required int messageId,
    required List<int> bytes,
    required String filename,
    String? caption,
    String? reply,
  }) async {
    final url = _buildMethodUri('editMessageMedia');

    var request = http.MultipartRequest('POST', url);
    request.fields
      ..['chat_id'] = chatId.toString()
      ..['message_id'] = messageId.toString()
      ..['media'] = jsonEncode(<String, Object?>{
        'type': 'photo',
        'media': 'attach://media',
        if (caption != null) ...<String, Object?>{
          'parse_mode': 'MarkdownV2',
          'caption': caption,
          'show_caption_above_media': true,
        },
      });
    if (reply != null) request.fields['reply_markup'] = reply;
    request.files.add(http.MultipartFile.fromBytes('media', bytes, filename: filename));
    final response = await request.send();
    if (response.statusCode == 200 || response.statusCode == 400) return;
    l.w('Failed to edit message media: status code ${response.statusCode}', StackTrace.current);
    throw Exception('Failed to edit message media: status code ${response.statusCode}');
  }

  /// Answer a callback query.
  Future<void> answerCallbackQuery(String callbackQueryId, String text, {bool arlert = false}) async {
    final url = _buildMethodUri('answerCallbackQuery');
    final response = await _client.post(
      url,
      body: _jsonEncoder.convert({
        'callback_query_id': callbackQueryId,
        if (text.isNotEmpty) 'text': text,
        if (arlert) 'show_alert': arlert,
      }),
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode == 200 || response.statusCode == 400) return;
    l.w('Failed to answer callback query: status code ${response.statusCode}', StackTrace.current);
    throw Exception('Failed to answer callback query: status code ${response.statusCode}');
  }

  /// Delete a message from a chat.
  Future<void> deleteMessage(int chatId, int messageId) async {
    final url = _buildMethodUri('deleteMessage');
    final response = await _client.post(
      url,
      body: _jsonEncoder.convert({'chat_id': chatId, 'message_id': messageId}),
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode == 200 || response.statusCode == 400) return;
    l.w('Failed to delete message: status code ${response.statusCode}', StackTrace.current);
    throw Exception('Failed to delete message: status code ${response.statusCode}');
  }

  /// Delete messages from a chat.
  Future<void> deleteMessages(int chatId, Set<int> messageIds) async {
    if (messageIds.isEmpty) return;
    if (messageIds.length == 1) return deleteMessage(chatId, messageIds.single);
    final url = _buildMethodUri('deleteMessages');
    final toDelete = messageIds.toList(growable: false);
    final length = toDelete.length;
    for (var i = 0; i < length; i += 100) {
      final response = await _client.post(
        url,
        body: _jsonEncoder.convert({'chat_id': chatId, 'message_ids': toDelete.sublist(i, math.min(i + 100, length))}),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200 || response.statusCode == 400) continue;
      l.w('Failed to delete messages: status code ${response.statusCode}', StackTrace.current);
      throw Exception('Failed to delete messages: status code ${response.statusCode}');
    }
  }

  /// [untilDate] - Date when the user will be unbanned; Unix time.
  /// If user is banned for more than 366 days or less than 30 seconds
  /// from the current time they are considered to be banned forever.
  /// Applied for supergroups and channels only.
  Future<void> banUser(int chatId, int userId, {int? untilDate}) async {
    final url = _buildMethodUri('banChatMember');
    final response = await _client.post(
      url,
      body: _jsonEncoder.convert({
        'chat_id': chatId,
        'user_id': userId,
        if (untilDate != null) 'until_date': untilDate,
      }),
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode == 200 || response.statusCode == 400) return;
    l.w('Failed to ban user: status code ${response.statusCode}', StackTrace.current);
    throw Exception('Failed to ban user: status code ${response.statusCode}');
  }

  /// [onlyIfBanned] - Do nothing if the user is not banned.
  Future<void> unbanUser(int chatId, int userId, {bool onlyIfBanned = true}) async {
    final url = _buildMethodUri('unbanChatMember');
    final response = await _client.post(
      url,
      body: _jsonEncoder.convert({'chat_id': chatId, 'user_id': userId, if (onlyIfBanned) 'only_if_banned': true}),
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode == 200 || response.statusCode == 400) return;
    l.w('Failed to unban user: status code ${response.statusCode}', StackTrace.current);
    throw Exception('Failed to unban user: status code ${response.statusCode}');
  }

  /// Get telegram chat info.
  Future<Map<String, Object?>> getChatInfo(int chatUd) async {
    final url = _buildMethodUri('getChat');
    final response = await _client.post(
      url,
      body: _jsonEncoder.convert({'chat_id': chatUd}),
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode != 200) {
      l.w('Failed to get chat info: status code ${response.statusCode}', StackTrace.current);
      throw Exception('Failed to get chat info: status code ${response.statusCode}');
    }
    final result = _jsonDecoder.convert(response.bodyBytes);
    if (result case <String, Object?>{'ok': true, 'result': Map<String, Object?> chatInfo}) {
      return chatInfo;
    } else if (result case <String, Object?>{'ok': false, 'description': String description}) {
      l.w('Failed to get chat info: $description', StackTrace.current, result);
      throw Exception('Failed to get chat info: $description');
    } else {
      l.w('Failed to get chat info', StackTrace.current, result);
      throw Exception('Failed to get chat info');
    }
  }
}
