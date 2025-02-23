import 'dart:io' as io;

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:vixen/src/arguments.dart';
import 'package:vixen/src/database.dart';
import 'package:vixen/src/server/middlewares.dart';
import 'package:vixen/src/server/routes.dart';

Future<io.HttpServer> startServer({required Database database, required Arguments arguments}) async {
  final $router =
      Router(notFoundHandler: $notFound)
        ..get('/<ignored|health|healthz|status>', $healthCheck)
        ..get('/admin/logs', $adminLogs)
        ..get('/admin/logs/<id>', $adminLogs)
        ..get('/admin/<ignored|db|database|sqlite|sqlite3>', $adminDatabase)
        //..get('/stat', $stat)
        ..all('/<ignored|.*>', $notFound);

  final pipeline = const Pipeline()
      .addMiddleware(handleErrors())
      .addMiddleware(logPipeline())
      .addMiddleware(cors())
      .addMiddleware(authorization(arguments.secret))
      .addMiddleware(injector(arguments: arguments, database: database))
      .addHandler($router.call);

  return await shelf_io.serve(
    pipeline,
    arguments.address,
    arguments.port,
    poweredByHeader: 'Vixen Bot',
    shared: false,
    backlog: 64,
  );
}
