import 'dart:convert';
import 'dart:io' as io;

import 'package:l/l.dart';
import 'package:meta/meta.dart';
import 'package:shelf/shelf.dart';
import 'package:stack_trace/stack_trace.dart' as st;
import 'package:vixen/src/database.dart';
import 'package:vixen/src/server/responses.dart';

/// Response encoder
final Converter<Map<String, Object?>, String> _responseEncoder =
    const JsonEncoder().cast<Map<String, Object?>, String>();

/// Middleware which prints the time of the request, the elapsed time for the
/// inner handlers, the response's status code and the request URI.
Middleware logPipeline() => logRequests(logger: (msg, isError) => isError ? l.w(msg) : l.d(msg));

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
Middleware injector({required Database database, Map<String, Object?>? dependencies}) =>
    (innerHandler) =>
        (request) => innerHandler(
          request.change(
            context: <String, Object?>{
              ...request.context,
              ...?dependencies,
              Dependencies._key: Dependencies._(database: database),
            },
          ),
        );

@immutable
final class Dependencies {
  factory Dependencies.of(Request request) => request.context[_key] as Dependencies;

  const Dependencies._({required this.database});

  static const String _key = '_@DEPENDENCIES';

  // ignore: unused_element
  void _inject(Request request) => request.change(context: <String, Object?>{...request.context, _key: this});

  /// SQLite database.
  final Database database;
}
