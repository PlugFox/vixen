import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:vixen/src/arguments.dart';
import 'package:vixen/src/database.dart';
import 'package:vixen/src/server/middlewares.dart';
import 'package:vixen/src/server/routes.dart';

Future<void> startServer({required Database database, required Arguments arguments}) async {
  final dependencies = Dependencies(database: database, arguments: arguments);

  final $router =
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
        // --- Not found --- //
        //..get('/stat', $stat)
        ..all('/<ignored|.*>', $ALL$NotFound);

  final pipeline = const Pipeline()
      .addMiddleware(handleErrors())
      .addMiddleware(logPipeline())
      .addMiddleware(cors())
      .addMiddleware(authorization(dependencies.arguments.secret))
      .addMiddleware(injector(dependencies))
      .addHandler($router.call);

  await shelf_io.serve(
    pipeline,
    dependencies.arguments.address,
    dependencies.arguments.port,
    poweredByHeader: 'Vixen Bot',
    shared: false,
    backlog: 64,
  );
}
