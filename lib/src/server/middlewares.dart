import 'dart:convert';
import 'dart:io' as io;

import 'package:l/l.dart';
import 'package:meta/meta.dart';
import 'package:shelf/shelf.dart';
import 'package:stack_trace/stack_trace.dart' as st;
import 'package:vixen/src/arguments.dart';
import 'package:vixen/src/bot.dart';
import 'package:vixen/src/database.dart';
import 'package:vixen/src/server/responses.dart';
import 'package:vixen/src/summarizer.dart';

/// Response encoder
final Converter<Map<String, Object?>, String> _responseEncoder =
    const JsonEncoder().cast<Map<String, Object?>, String>();

/// Middleware which prints the time of the request, the elapsed time for the
/// inner handlers, the response's status code and the request URI.
Middleware logPipeline() {
  String formatQuery(String query) => query == '' ? '' : '?$query';
  String elapsed(int microseconds) => switch (microseconds) {
    > 60_000_000 => '${(microseconds / 60_000_000).toStringAsFixed(1)}m',
    > 1000_000 => '${(microseconds / 1000_000).toStringAsFixed(1)}s',
    > 1000 => '${(microseconds / 1000).toStringAsFixed(1)}ms',
    _ => '${microseconds}us',
  };
  return (innerHandler) => (request) {
    final watch = Stopwatch()..start();
    const nbsp = '\u00A0';
    return Future.sync(() => innerHandler(request)).then(
      (response) {
        final duration = elapsed(watch.elapsedMicroseconds);
        l.vvvvvv(
          '${duration.padRight(7)}$nbsp'
          '${request.method.padRight(7)}$nbsp[${response.statusCode}]$nbsp' // 7 - longest standard HTTP method
          '${request.requestedUri.path}${formatQuery(request.requestedUri.query)}',
        );
        return response.change(headers: <String, Object?>{...response.headers, 'X-Duration': duration});
      },
      onError: (Object error, StackTrace stackTrace) {
        if (error is HijackException) throw error;
        l.w(
          '${elapsed(watch.elapsedMicroseconds)}$nbsp'
          '${request.method.padRight(7)}$nbsp[ERR]$nbsp' // 7 - longest standard HTTP method
          '${request.requestedUri.path}${formatQuery(request.requestedUri.query)}',
          stackTrace,
          <String, Object?>{'error': error.toString()},
        );
        throw error; // ignore: only_throw_errors
      },
    );
  };
}

/// Injects a [token] to the request context if
/// 'Authorization: Bearer token' is present in the request headers.
Middleware authorization(String? token) {
  final emptyToken = token == null || token.length < 6;
  return (innerHandler) => (request) {
    final authorization = switch (request.headers['Authorization'] ?? request.url.queryParameters['token']) {
      String text when text.startsWith('Bearer ') => text.substring(7),
      String text => text,
      _ => null,
    };
    if (authorization != null || request.url.pathSegments.firstOrNull == 'admin') {
      if (emptyToken || authorization != token) return Responses.error(const UnauthorizedException());
      return innerHandler(request.change(context: <String, Object>{...request.context, 'authorization': true}));
    } else {
      return innerHandler(request.change(context: <String, Object>{...request.context, 'authorization': false}));
    }
  };
}

/// Normalize the query path.
/* Middleware normalizePath() =>
    (innerHandler) => (request) {
      final normalized = request.url.normalizePath();
      return innerHandler(normalized != request.url ? request.change(...) : request);
    }; */

/// Middleware that catches all errors and sends a JSON response with the error
/// message. If the error is not an instance of [HttpException], it will be
/// wrapped into one with the status code 500.
Middleware handleErrors({bool showStackTrace = false}) =>
    (handler) =>
        (request) => Future.sync(() => handler(request)).then<Response>((response) => response).catchError(
          // ignore: avoid_types_on_closure_parameters
          (Object error, StackTrace? stackTrace) {
            final result =
                error is HttpException
                    ? error
                    : HttpException(
                      status: io.HttpStatus.internalServerError,
                      code: 'internal',
                      message: 'Internal Server Error',
                      data: <String, Object?>{
                        'path': request.url.path,
                        'query': request.url.queryParameters,
                        'method': request.method,
                        'headers': request.headers,
                        'error': showStackTrace ? error.toString() : _errorRepresentation(error),
                        if (showStackTrace && stackTrace != null) 'stack_trace': st.Trace.format(stackTrace),
                      },
                    );
            return Response(
              result.status,
              body: _responseEncoder.convert(result.toJson()),
              headers: <String, String>{'Content-Type': io.ContentType.json.value},
            );
          },
        );

String _errorRepresentation(Object? error) => switch (error) {
  FormatException _ => 'Format exception',
  HttpException _ => 'HTTP exception',
  io.HttpException _ => 'HTTP exception',
  UnimplementedError _ => 'Unimplemented error',
  UnsupportedError _ => 'Unsupported error',
  RangeError _ => 'Range error',
  StateError _ => 'State error',
  ArgumentError _ => 'Argument error',
  TypeError _ => 'Type error',
  OutOfMemoryError _ => 'Out of memory error',
  StackOverflowError _ => 'Stack overflow error',
  Exception _ => 'Exception',
  Error _ => 'Error',
  _ => 'Unknown error',
};

Middleware cors([Map<String, String>? headers]) =>
    (innerHandler) =>
        (request) => Future<Response>.sync(() => innerHandler(request)).then(
          (response) => response.change(
            headers: <String, String>{
              ...response.headers,
              ...?headers,
              'Access-Control-Allow-Origin': '*',
              'Access-Control-Allow-Methods': 'GET, POST, HEAD, OPTIONS',
              'Access-Control-Allow-Headers': '*',
              'Access-Control-Allow-Credentials': 'true',
              'Access-Control-Max-Age': '86400',
              'Access-Control-Expose-Headers': '*',
              'Access-Control-Request-Headers': '*',
              'Access-Control-Request-Method': '*',
            },
          ),
        );

/// Injects a [Map] of dependencies into the request context.
Middleware injector(Dependencies dependencies, {Map<String, Object?>? extra}) =>
    (innerHandler) =>
        (request) => innerHandler(
          request.change(context: <String, Object?>{...request.context, ...?extra, Dependencies._key: dependencies}),
        );

@immutable
final class Dependencies {
  const Dependencies({required this.arguments, required this.database, required this.bot, required this.summarizer});

  factory Dependencies.of(Request request) => request.context[_key] as Dependencies;

  static const String _key = '_@DEPENDENCIES';

  // ignore: unused_element
  void _inject(Request request) => request.change(context: <String, Object?>{...request.context, _key: this});

  /// Startup arguments.
  final Arguments arguments;

  /// SQLite database.
  final Database database;

  /// Bot instance.
  final Bot bot;

  /// OpenAI summarizer.
  final Summarizer? summarizer;
}
