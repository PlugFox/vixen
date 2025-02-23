import 'dart:io' as io;

import 'package:drift/drift.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:vixen/src/server/middlewares.dart';
import 'package:vixen/src/server/responses.dart';

Response $healthCheck(Request request) =>
    Response.ok('{"data": {"status": "ok"}}', headers: <String, String>{'Content-Type': io.ContentType.json.value});

Future<Response> $notFound(Request request) => Responses.error(
  NotFoundException(
    data: <String, Object?>{
      'method': request.method,
      'headers': request.headers,
      'path': request.url.path,
      'query': request.url.queryParameters,
    },
  ),
);

Future<Response> $adminLogs(Request request) async {
  final $id = request.params['id'];
  final db = Dependencies.of(request).database;
  if ($id case String id when id.isNotEmpty) {
    final id = int.tryParse($id);
    if (id == null)
      return Responses.error(BadRequestException(detail: 'Invalid ID', data: <String, Object?>{'id': $id}));
    final log =
        await (db.select(db.logTbl)
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
    final query = db.select(db.logTbl);
    final $level = request.url.queryParameters['level'];
    final int level;
    if ($level case String value when value.isNotEmpty) {
      level = int.tryParse(value) ?? 3;
    } else {
      level = 3;
    }
    final logs =
        await (query
              ..where((tbl) => tbl.level.isSmallerOrEqualValue(level))
              ..orderBy([(u) => OrderingTerm(expression: u.time, mode: OrderingMode.desc)])
              ..limit(100))
            .get();
    return Responses.ok(<String, Object?>{
      'items': logs
          .map((e) => <String, Object?>{'id': e.id, 'level': e.level, 'message': e.message, 'time': e.time})
          .toList(growable: false),
    });
  }
}
