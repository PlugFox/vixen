import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:vixen/src/arguments.dart';
import 'package:vixen/src/bot.dart';
import 'package:vixen/src/database.dart';
import 'package:vixen/src/server/middlewares.dart';
import 'package:vixen/src/server/routes.dart';
import 'package:vixen/src/summarizer.dart';

Future<void> startServer({
  required Database database,
  required Bot bot,
  required Arguments arguments,
  Summarizer? summarizer,
}) async {
  final dependencies = Dependencies(database: database, bot: bot, arguments: arguments, summarizer: summarizer);

  final pipeline = const Pipeline()
      .addMiddleware(handleErrors())
      /* .addMiddleware(normalizePath()) */
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
