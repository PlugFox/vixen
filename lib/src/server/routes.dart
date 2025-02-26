import 'dart:convert';
import 'dart:io' as io;

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:vixen/src/reports.dart';
import 'package:vixen/src/server/middlewares.dart';
import 'package:vixen/src/server/responses.dart';
import 'package:vixen/vixen.dart';

final Router $router =
    Router(notFoundHandler: $ALL$NotFound)
      // --- Meta --- //
      ..get('/<ignored|health|healthz|status>', $GET$HealthCheck)
      ..get('/<ignored|about|version>', $GET$About)
      // --- Database --- //
      ..get('/admin/<ignored|db|database|sqlite|sqlite3>', $GET$Admin$Database)
      // --- Logs --- //
      ..get('/admin/logs', $GET$Admin$Logs)
      ..get('/admin/logs/<id>', $GET$Admin$Logs)
      // --- Users --- //
      ..get('/admin/users/verified', $GET$Admin$Users$Verified)
      ..put('/admin/users/verified', $PUT$Admin$Users$Verified)
      ..delete('/admin/users/verified', $DELETE$Admin$Users$Verified)
      // --- Messages --- //
      ..get('/admin/messages/deleted', $GET$Admin$Messages$Deleted)
      ..get('/admin/messages/deleted/hash', $GET$Admin$Messages$Deleted$Hash)
      // --- Reports --- //
      ..get('/report', $GET$Report)
      ..get('/admin/report', $GET$Admin$Report)
      // --- Not found --- //
      //..get('/stat', $stat)
      ..all('/<ignored|.*>', $ALL$NotFound);

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

Future<Response> $GET$Admin$Messages$Deleted$Hash(Request request) async {
  final db = Dependencies.of(request).database;
  final limit = switch (request.url.queryParameters['limit']?.trim()) {
    String value when value.isNotEmpty => int.tryParse(value) ?? 1000,
    _ => 1000,
  };
  final orderBy = switch (request.url.queryParameters['order']?.trim().toLowerCase()) {
    'count' => db.deletedMessageHash.count,
    'date' => db.deletedMessageHash.updateAt,
    'length' => db.deletedMessageHash.length,
    _ => db.deletedMessageHash.count,
  };
  final items =
      await (db.select(db.deletedMessageHash)
            ..limit(limit.clamp(1, 1000))
            ..orderBy([(u) => OrderingTerm(expression: orderBy, mode: OrderingMode.desc)]))
          .get();
  return Responses.ok(<String, Object?>{'count': items.length, 'items': items.map((e) => e.toJson()).toList()});
}

Future<Map<String, Object?>> _getReport({required Database db, required DateTime from, required DateTime to}) async {
  final reports = Reports(db: db);
  final mostActiveUsers = await reports.mostActiveUsers(from, to);
  final spamMessages = await reports.spamMessages(from, to);
  final bannedUsers = await reports.bannedMessages(from, to);
  final deletedCount = await reports.deletedCount(from, to);
  return <String, Object?>{
    'from': from.toIso8601String(),
    'to': to.toIso8601String(),
    'active': mostActiveUsers.entries
        .map(
          (e) => <String, Object?>{
            'cid': e.key,
            'users': e.value
                .map<Map<String, Object?>>(
                  (u) => <String, Object?>{
                    'uid': u.uid,
                    'username': u.username,
                    'seen': u.seen.toIso8601String(),
                    'count': u.count,
                  },
                )
                .toList(growable: false),
          },
        )
        .toList(growable: false),
    'spam': spamMessages
        .map<Map<String, Object?>>(
          (e) => <String, Object?>{'message': e.message, 'count': e.count, 'date': e.date.toIso8601String()},
        )
        .toList(growable: false),
    'deleted': deletedCount
        .map<Map<String, Object?>>((e) => <String, Object?>{'cid': e.cid, 'count': e.count})
        .toList(growable: false),
    'banned': bannedUsers
        .map(
          (e) => {
            'cid': e.cid,
            'uid': e.uid,
            'username': e.username,
            'reason': e.reason,
            'bannedAt': e.bannedAt.toIso8601String(),
            'expiresAt': e.expiresAt?.toIso8601String(),
          },
        )
        .toList(growable: false),
  };
}

var _$GET$ReportCache = (0, Future.value(const <String, Object?>{}));
Future<Response> $GET$Report(Request request) async {
  final now = DateTime.now();
  final date = DateTime(now.year, now.month, now.day);
  final value = (date.year << 9) | (date.month << 5) | date.day;
  if (value == _$GET$ReportCache.$1) return Responses.ok(await _$GET$ReportCache.$2);
  final result = _getReport(
    db: Dependencies.of(request).database,
    from: date.subtract(const Duration(days: 1)), // Beginning of yesterday
    to: date, // Beginning of today
  );
  _$GET$ReportCache = (value, result);
  return Responses.ok(await result);
}

Future<Response> $GET$Admin$Report(Request request) async {
  var from =
          switch (request.url.queryParameters['from']) {
            String iso when iso.isNotEmpty => DateTime.tryParse(iso),
            _ => null,
          } ??
          DateTime.now().subtract(const Duration(days: 1)),
      to =
          switch (request.url.queryParameters['to']) {
            String iso when iso.isNotEmpty => DateTime.tryParse(iso),
            _ => null,
          } ??
          DateTime.now();
  if (from.isAfter(to)) (from, to) = (to, from);
  final db = Dependencies.of(request).database;
  final report = await _getReport(db: db, from: from, to: to);
  return Responses.ok(report);
}
