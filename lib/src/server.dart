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
      Router(notFoundHandler: $notFound)
        ..get('/<ignored|health|healthz|status>', $healthCheck)
        ..get('/<ignored|about|version>', $about)
        ..get('/admin/logs', $adminLogs)
        ..get('/admin/logs/<id>', $adminLogs)
        ..get('/admin/<ignored|db|database|sqlite|sqlite3>', $adminDatabase)
        ..get('/admin/users/verified', $adminUsersVerifiedGet)
        ..put('/admin/users/verified', $adminUsersVerifiedPut)
        ..delete('/admin/users/verified', $adminUsersVerifiedDelete)
        //..get('/stat', $stat)
        ..all('/<ignored|.*>', $notFound);

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
