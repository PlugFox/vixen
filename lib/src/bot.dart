import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:l/l.dart';

final Converter<List<int>, Map<String, Object?>> _jsonDecoder =
    utf8.decoder.fuse(json.decoder).cast<List<int>, Map<String, Object?>>();

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
  Future<List<Map<String, Object?>>> _getUpdates(Uri url) async {
    final response = await _client.get(url);
    if (response.statusCode != 200) {
      l.w('Failed to fetch updates: status code', StackTrace.current, {'status': response.statusCode});
      return const [];
    }
    final update = _jsonDecoder.convert(response.bodyBytes);
    if (update['ok'] != true) {
      l.w('Failed to fetch updates: not ok', StackTrace.current, {'update': update});
      return const [];
    }
    final result = update['result'];
    if (result is! List) {
      l.w('Failed to fetch updates: wrong result type', StackTrace.current, {'result': result});
      return const [];
    }
    return result.whereType<Map<String, Object?>>().where((u) => u['update_id'] is int).toList(growable: false);
  }

  /// Handle updates by calling all the handlers for each update.
  @pragma('vm:prefer-inline')
  void _handleUpdates(List<Map<String, Object?>> updates) {
    for (final update in updates) {
      if (update['update_id'] case int id) {
        _offset = math.max(id + 1, _offset);
        for (final handler in _handlers) {
          try {
            handler(id, update);
          } on Object catch (error, stackTrace) {
            l.e('An error occurred while handling update #$id: $error', stackTrace, {'id': id, 'update': update});
            continue;
          }
        }
      }
    }
  }

  /// Delete a message from a chat.
  Future<void> deleteMessage(int chatId, int messageId) async {
    final url = _buildMethodUri('deleteMessage');
    final response = await _client.post(
      url,
      body: json.encode({'chat_id': chatId, 'message_id': messageId}),
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode != 200) throw Exception('Failed to delete message: status code ${response.statusCode}');
  }

  /// Delete messages from a chat.
  Future<void> deleteMessages(int chatId, Set<int> messageIds) async {
    if (messageIds.isEmpty) return;
    if (messageIds.length == 1) return deleteMessage(chatId, messageIds.single);
    final url = _buildMethodUri('deleteMessages');
    final toDelete = messageIds.toList(growable: false);
    for (var i = 0; i < toDelete.length; i += 100) {
      final response = await _client.post(
        url,
        body: json.encode({'chat_id': chatId, 'message_ids': toDelete.sublist(i, i + 100)}),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode != 200) throw Exception('Failed to delete messages: status code ${response.statusCode}');
    }
  }

  /// Start polling for updates.
  void start() => runZonedGuarded<void>(
    () {
      stop(); // Stop any previous poller
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
                  if (_offset > 0) 'offset': _offset.toString(),
                  'limit': '100',
                  'timeout': _interval.inSeconds.toString(),
                },
              ),
            ).timeout(_interval * 2);
            if (poller.isCompleted) return;
            _handleUpdates(updates);
            // Throttle the polling to avoid hitting the rate limit
            if (throttleStopwatch.elapsed < const Duration(seconds: 1)) {
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
}
