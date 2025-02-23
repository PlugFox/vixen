import 'dart:io' as io;

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:vixen/src/database.dart';
import 'package:vixen/src/server/middlewares.dart';
import 'package:vixen/src/server/routes.dart';

Future<io.HttpServer> startServer({
  required Database database,
  required String secret,
  Object? address,
  int? port,
}) async {
  final $router =
      Router(notFoundHandler: $notFound)
        ..get('/health', $healthCheck)
        ..get('/healthz', $healthCheck)
        ..get('/status', $healthCheck)
        ..get('/admin/logs', $adminLogs)
        ..get('/admin/logs/<id>', $adminLogs)
        //..get('/stat', $stat)
        ..all('/<ignored|.*>', $notFound);

  final pipeline = const Pipeline()
      .addMiddleware(handleErrors())
      .addMiddleware(logPipeline())
      .addMiddleware(cors())
      .addMiddleware(authorization(secret))
      .addMiddleware(injector(database: database))
      .addHandler($router.call);

  return await shelf_io.serve(
    pipeline,
    address ?? io.InternetAddress.anyIPv4,
    port ?? 8080,
    poweredByHeader: 'Vixen Bot',
    shared: false,
    backlog: 64,
  );
}
