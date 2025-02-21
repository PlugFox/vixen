import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:l/l.dart';

final Converter<List<int>, Map<String, Object?>> _jsonDecoder =
    utf8.decoder.fuse(json.decoder).cast<List<int>, Map<String, Object?>>();

class Bot {
  Bot({
    required String token,
    http.Client? client,
    int? offset,
    Duration interval = const Duration(seconds: 30),
    void Function(Map<String, Object?> update)? onUpdate,
  }) : _token = token,
       _client = client ?? http.Client(),
       _offset = offset ?? 0,
       _interval = interval,
       _onUpdate = onUpdate;

  final String _token;
  final http.Client _client;
  final Duration _interval;
  int _offset;
  Completer<void>? _poller;

  final void Function(Map<String, Object?> update)? _onUpdate;

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

  void _handleUpdate(Map<String, Object?> update) {
    if (update['update_id'] case int id) _offset = math.max(id + 1, _offset);
    _onUpdate?.call(update);
  }

  void start() {
    final url = Uri.parse('https://api.telegram.org/bot$_token/getUpdates');
    final poller = _poller = Completer<void>()..future.ignore();
    //final stopwatch = Stopwatch()..start();
    Future<void>(() async {
      while (true) {
        //stopwatch.reset();
        try {
          if (poller.isCompleted) return;
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
          for (final update in updates) {
            try {
              _handleUpdate(update);
            } on Object catch (error, stackTrace) {
              l.e('An error occurred while handling update: $error', stackTrace, {'update': update});
              continue;
            }
          }
        } on Object catch (error, stackTrace) {
          l.e('An error occurred while fetching updates: $error', stackTrace);
        }
        //if (stopwatch.elapsed < _interval) await Future<void>.delayed(_interval - stopwatch.elapsed);
      }
    });
  }

  void stop() {
    _poller?.complete();
  }
}
