import 'dart:convert';
import 'dart:io' as io;

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:vixen/src/server/middlewares.dart';
import 'package:vixen/src/server/responses.dart';
import 'package:vixen/vixen.dart';

Response $GET$HealthCheck(Request request) =>
    Response.ok('{"data": {"status": "ok"}}', headers: <String, String>{'Content-Type': io.ContentType.json.value});

Future<Response> $ALL$NotFound(Request request) => Responses.error(
  NotFoundException(
    data: <String, Object?>{
      'method': request.method,
      'headers': request.headers,
      'path': request.url.path,
      'query': request.url.queryParameters,
    },
  ),
);

Future<Response> $GET$About(Request request) => Responses.ok(<String, Object?>{
  'name': Pubspec.name,
  'description': Pubspec.description,
  'repository': Pubspec.repository,
  'semversion': Pubspec.version.representation,
  'timestamp': Pubspec.timestamp.toIso8601String(),
  'datetime': DateTime.now().toIso8601String(),
  'timezone': DateTime.now().timeZoneName,
  'locale': io.Platform.localeName,
  'platform': io.Platform.operatingSystem,
  'dart': io.Platform.version,
  'cpu': io.Platform.numberOfProcessors,
});

Future<Response> $GET$Admin$Logs(Request request) async {
  final $id = request.params['id'];
  final db = Dependencies.of(request).database;
  if ($id case String id when id.isNotEmpty) {
    final id = int.tryParse($id);
    if (id == null)
      return Responses.error(BadRequestException(detail: 'Invalid ID', data: <String, Object?>{'id': $id}));
    final log =
        await (db.select(db.logger)
              ..where((tbl) => tbl.id.equals(id))
              ..limit(1))
            .getSingleOrNull();
    if (log == null) return Responses.error(NotFoundException(data: <String, Object?>{'id': id}));
    return Responses.ok(<String, Object?>{
      'id': log.id,
      'level': log.level,
      'message': log.message,
      'time': log.time,
      if (log.stack != null) 'stack': log.stack,
      if (log.context != null) 'context': log.context,
    });
  } else {
    final query = db.select(db.logger);
    final level = switch (request.url.queryParameters['level']) {
          String value when value.isNotEmpty => int.tryParse(value) ?? 3,
          _ => 3,
        },
        limit = switch (request.url.queryParameters['limit']) {
          String value when value.isNotEmpty => int.tryParse(value) ?? 1000,
          _ => 1000,
        };
    final logs =
        await (query
              ..where((tbl) => tbl.level.isSmallerOrEqualValue(level.clamp(1, 6)))
              ..orderBy([(u) => OrderingTerm(expression: u.time, mode: OrderingMode.desc)])
              ..limit(limit.clamp(1, 1000)))
            .get();
    return Responses.ok(<String, Object?>{
      'count': logs.length,
      'items': logs
          .map((e) => <String, Object?>{'id': e.id, 'level': e.level, 'message': e.message, 'time': e.time})
          .toList(growable: false),
    });
  }
}

Future<Response> $GET$Admin$Database(Request request) async {
  final path = Dependencies.of(request).arguments.database;
  if (path.isEmpty)
    return Responses.error(const NotFoundException(detail: 'Database path is empty'));
  else if (path == ':memory:')
    return Responses.error(const NotFoundException(detail: 'In-memory database is not supported'));

  switch (path.trim().toLowerCase()) {
    case '':
      return Responses.error(const NotFoundException(detail: 'Database path is empty'));
    case ':memory:':
      return Responses.error(const NotFoundException(detail: 'In-memory database is not supported'));
    default:
      final file = io.File(path);
      if (!file.existsSync())
        return Responses.error(
          NotFoundException(detail: 'Database file does not exist', data: <String, Object?>{'path': path}),
        );
      final bytes = await file.readAsBytes();
      return Responses.ok(
        bytes,
        headers: <String, String>{
          io.HttpHeaders.contentTypeHeader: 'application/octet-stream', // Universal MIME type
          io.HttpHeaders.contentLengthHeader: bytes.length.toString(), // Size in bytes
          io.HttpHeaders.contentDisposition: 'attachment; filename="vixen.db"', // Download as file
          io.HttpHeaders.cacheControlHeader: 'no-cache, no-store, must-revalidate', // Without caching
          io.HttpHeaders.pragmaHeader: 'no-cache', // For HTTP/1.0 compatibility
          io.HttpHeaders.expiresHeader: '0', // Outdated content
          io.HttpHeaders.acceptRangesHeader: 'bytes', // Allow partial requests
        },
      );
  }
}

Future<Response> $GET$Admin$Users$Verified(Request request) async {
  final db = Dependencies.of(request).database;
  var ids =
      await (db.selectOnly(db.verified)..addColumns([db.verified.userId])).map((e) => e.read(db.verified.userId)).get();
  ids = ids.whereType<int>().toList(growable: false);
  return Responses.ok(<String, Object?>{'count': ids.length, 'items': ids});
}

Future<Response> $PUT$Admin$Users$Verified(Request request) async {
  final body = await request.readAsString();
  final json = jsonDecode(body);
  final items = json['data'] ?? json['users'] ?? json['verified'] ?? json['items'];
  if (items is! List<Object?>) return Responses.error(const BadRequestException(detail: 'Invalid request body'));
  var j = 0;
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item case <String, Object?>{'chatId': int chatId, 'userId': int userId, 'name': String name}) {
      final verifiedAt = switch (item['verifiedAt']) {
        int n => n,
        _ => null,
      };
      final reason = item['reason']?.toString();
      items[i] = (chatId: chatId, userId: userId, name: name, verifiedAt: verifiedAt, reason: reason);
      j++;
    }
  }
  items.length = j;
  final users = items.whereType<({int chatId, int userId, String name, int? verifiedAt, String? reason})>().toList(
    growable: false,
  );
  if (users.isEmpty) return Responses.error(const BadRequestException(detail: 'Missing users'));
  await Dependencies.of(request).database.verifyUsers(users);
  return Responses.ok(<String, Object?>{'count': users.length});
}

Future<Response> $DELETE$Admin$Users$Verified(Request request) async {
  final body = await request.readAsString();
  final json = jsonDecode(body);
  final items = json['data'] ?? json['ids'] ?? json['users'] ?? json['items'];
  if (items is! List) return Responses.error(const BadRequestException(detail: 'Invalid request body'));
  final ids = items.whereType<int>().toSet();
  if (ids.isEmpty) return Responses.error(const BadRequestException(detail: 'Missing user IDs'));
  final count = await Dependencies.of(request).database.unverifyUsers(ids);
  return Responses.ok(<String, Object?>{'count': count});
}

Future<Response> $GET$Admin$Messages$Deleted(Request request) async {
  final limit = switch (request.url.queryParameters['limit']) {
    String value when value.isNotEmpty => int.tryParse(value) ?? 1000,
    _ => 1000,
  };
  final db = Dependencies.of(request).database;
  final items =
      await (db.select(db.deletedMessage)
            ..limit(limit.clamp(1, 1000))
            ..orderBy([(u) => OrderingTerm(expression: u.date, mode: OrderingMode.desc)]))
          .get();
  return Responses.ok(<String, Object?>{'count': items.length, 'items': items.map((e) => e.toJson()).toList()});
}
