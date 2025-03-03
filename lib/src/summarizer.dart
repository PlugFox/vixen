import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:vixen/src/database.dart';

/// A summarizer that uses the OpenAI API to summarize chat messages.
class Summarizer {
  Summarizer({required String key, required Database db, http.Client? client, String? model, String? url})
    : _key = key,
      _db = db,
      _client = client ?? http.Client(),
      _model = model ?? 'gpt-4o-mini',
      _url = Uri.parse(url ?? 'https://api.openai.com/v1/chat/completions');

  /// Secret API key
  final String _key;

  /// Database instance
  final Database _db;

  /// OpenAI model
  final String _model;

  /// API endpoint
  final Uri _url;

  /// HTTP client
  final http.Client _client;

  /// Conversion factor from characters to tokens
  //static const double _tokenPerChar = 1; // 4 / 3;

  Future<List<Map<String, Object?>>> _fetchSummary(List<Map<String, Object?>> batch) async {
    const batchEncoder = JsonEncoder.withIndent(' ');
    final bodyEncoder = const JsonEncoder().fuse(const Utf8Encoder());

    final requestBody = <String, Object?>{
      'model': _model, // gpt-4o-mini | gpt-4-turbo || gpt-4
      'messages': <Map<String, Object?>>[
        <String, Object?>{'role': 'system', 'content': _promt},
        <String, Object?>{
          'role': 'user',
          'content': batchEncoder.convert(<String, Object?>{'count': batch.length, 'messages': batch}),
        },
      ],
      'temperature': 0.7,
      'max_tokens': 2000,
      'response_format': <String, Object?>{'type': 'json_object'},
    };

    final response = await _client.post(
      _url,
      headers: <String, String>{
        'Authorization': 'Bearer $_key',
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
        'Accept-Charset': 'UTF-8',
      },
      body: bodyEncoder.convert(requestBody),
    );

    if (response.statusCode != 200)
      throw Exception('Failed to summarize chat messages: ${response.statusCode} ${response.body}');

    final decoder =
        const Utf8Decoder(allowMalformed: true).fuse(const JsonDecoder()).cast<List<int>, Map<String, Object?>>();

    try {
      final responseBody = decoder.convert(response.bodyBytes);
      if (responseBody case <String, Object?>{'choices': List<Object?> choices} when choices.isNotEmpty) {
        final choice = choices.firstOrNull;
        if (choice case <String, Object?>{
          'message': <String, Object?>{'content': String content},
        } when content.isNotEmpty) {
          final json = jsonDecode(content);
          if (json case <String, Object?>{'topics': List<Object?> topics}) {
            return topics.whereType<Map<String, Object?>>().toList(growable: false);
          }
        }
      }
    } on Object catch (e, s) {
      Error.throwWithStackTrace(Exception('Failed to parse chat summary ${response.body} with error: $e'), s);
    }
    throw Exception('Failed to parse chat summary: ${response.body}');
  }

  List<SummaryTopic> _extractTopics(List<Map<String, Object?>> data) => data
    .map<SummaryTopic?>((e) {
      if (e case <String, Object?>{'title': String title, 'summary': String summary, 'start_message_id': int message}) {
        final points = switch (e) {
          <String, Object?>{'key_points': List<Object?> points} when points.isNotEmpty => points
              .whereType<String>()
              .toList(growable: false),
          _ => const <String>[],
        };
        final conclusions = switch (e) {
          <String, Object?>{'conclusions': List<Object?> conclusions} when conclusions.isNotEmpty => conclusions
              .whereType<String>()
              .toList(growable: false),
          _ => const <String>[],
        };
        final quotes = switch (e) {
          <String, Object?>{'notable_quotes': List<Object?> quotes} when quotes.isNotEmpty => quotes
              .whereType<Map<String, Object?>>()
              .map<SummaryQuote?>(
                (e) => switch (e) {
                  <String, Object?>{
                    'quote': String quote,
                    'user_id': int uid,
                    'username': String username,
                    'message_id': int message,
                  } =>
                    (quote: quote, uid: uid, username: username, message: message),
                  _ => null,
                },
              )
              .whereType<SummaryQuote>()
              .where((e) => e.quote.isNotEmpty && e.username.isNotEmpty && e.message > 0 && e.uid > 0)
              .toList(growable: false),
          _ => const <SummaryQuote>[],
        };
        return (
          title: title,
          summary: summary,
          message: message,
          count: switch (e['number_of_messages']) {
            int count when count > 0 => count,
            String count when count.isNotEmpty => int.tryParse(count) ?? 0,
            _ => 0,
          },
          points: points,
          conclusions: conclusions,
          quotes: quotes,
        );
      } else {
        return null;
      }
    })
    .whereType<SummaryTopic>()
    .where((e) => e.count > 0)
    .toList(growable: false)..sort((a, b) => b.count.compareTo(a.count));

  Future<List<SummaryTopic>> call({required int chatId, DateTime? from, DateTime? to}) async {
    var $to = to ?? DateTime.now();
    var $from = from ?? $to.subtract(const Duration(days: 1));
    if ($from.isAfter($to)) ($from, $to) = ($to, $from);
    final toUnix = $to.millisecondsSinceEpoch ~/ 1000, fromUnix = $from.millisecondsSinceEpoch ~/ 1000;

    final messages =
        await (_db.select(_db.allowedMessage)
              ..where((tbl) => tbl.date.isBetweenValues(fromUnix, toUnix) & tbl.chatId.equals(chatId))
              ..orderBy([(u) => OrderingTerm(expression: u.date, mode: OrderingMode.asc)]))
            .get();

    final summaryMessages = messages
        .where((e) => e.length > 12 && e.content.length > 12)
        .map(
          (e) => <String, Object?>{
            'id': e.messageId,
            if (e.replyTo != null) 'replyTo': e.replyTo,
            'date': DateTime.fromMillisecondsSinceEpoch(e.date * 1000).toIso8601String(),
            'user_id': e.userId,
            'username': e.username,
            'type': e.type,
            'content': e.content,
          },
        )
        .toList(growable: false);

    if (summaryMessages.isEmpty) return const <SummaryTopic>[];
    if (summaryMessages.length < 10) return const <SummaryTopic>[];
    final data = await _fetchSummary(summaryMessages);
    return _extractTopics(data);
  }
}

typedef SummaryQuote = ({int message, String quote, int uid, String username});

typedef SummaryTopic =
    ({
      String title,
      String summary,
      int message,
      int count,
      List<String> points,
      List<String> conclusions,
      List<SummaryQuote> quotes,
    });

const String _promt = '''
Ты — продвинутый ассистент, который составляет саммари обсуждений в чате.
Твоя задача — проанализировать сообщения и создать структурированное резюме с ключевыми темами, основными моментами, выводами и заметными цитатами.
Учитывай дату, ответы на сообщения и ветки обсуждений.
Считай количество сообщений, чтобы оценить, насколько обширно было обсуждение.
Включи в саммари только важные детали и исключи ненужную информацию.
По возможности начинай заголовок с эмодзи, чтобы сделать его более привлекательным.
Я ожидаю по топику на каждое из обсуждений.
Если ты не можешь найти ключевые моменты, цитаты или выводы, оставь соответствующие поля пустыми.
Если топиков не существует, верни пустой список.
Форматируй ответ строго в виде JSON-объекта.

Структура вывода:
{
  "topics": [
    {
      "title": "Тема 1",
      "start_message_id": 123,
      "number_of_messages": 10,
      "summary": "🤔 Очень краткое резюме обсуждения",
      "key_points": ["Ключевой момент 1", "Ключевой момент 2"],
      "conclusions": ["Вывод 1", "Вывод 2"],
      "notable_quotes": [
        {
          "quote": "Какой-то интересный комментарий",
          "user_id": 123,
          "username": "user",
          "message_id": 456
        }
      ]
    }
  ]
}

Используй эмодзи и форматирование там, где это уместно, чтобы сделать саммари более читаемым и привлекательным.
Саммари должно быть на языке, который преобладает в обсуждении.
Например, если большинство сообщений на русском, делай саммари тоже на русском.
Все текстовые данные должны быть в кодировке UTF-8.
''';
